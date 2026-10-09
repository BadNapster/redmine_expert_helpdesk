# Core of the helpdesk plugin: processing of incoming mail.
#
# The mail backend is resolved per mailbox through MailProvider (Microsoft
# Graph or generic IMAP/SMTP); this flow is provider-neutral.
#
# Flow per mailbox:
#   1. Load messages from the source folder through the provider
#   2. Check the sender against the black-/whitelist
#   3. Apply the "ignore" rules
#   4. Hand the MIME to Redmine's own MailHandler
#      (does ticket creation, reply matching via In-Reply-To / [#id] subject,
#       attachments and user creation)
#   5. Apply the rules to the created ticket, link the contact
#   6. Send the autoresponder for new tickets
#   7. Enqueue the AI summary and the completeness check asynchronously
#   8. Move the message to the target folder

module RedmineExpertHelpdesk
  class MailProcessor
    Result = Struct.new(:processed, :created_issues, :updated_issues, :skipped, :errors) do
      def to_h
        { :processed => processed, :created_issues => created_issues,
          :updated_issues => updated_issues, :skipped => skipped, :errors => errors }
      end
    end

    # The second argument stays positional for backwards compatibility - tests
    # inject a fake provider through it.
    def initialize(mailbox, provider = nil)
      @mailbox = mailbox
      @provider = provider || MailProvider.for(mailbox)
    end

    # Processes all messages of the mailbox. Returns a Result object.
    # In maintenance mode nothing is fetched; the run is registered first so a
    # status read never misses a fetch that got past the check (see Maintenance).
    def process_all(limit = 25)
      HelpdeskFetchRun.track(@mailbox) do |run|
        @run = run
        next Result.new(0, [], [], 0, []) if Maintenance.active?(:fresh => true)

        # One session for the whole cycle: IMAP opens a single connection here
        # instead of one per message. Graph ignores it.
        @provider.with_session { run_cycle(limit) }
      end
    ensure
      @run = nil
    end

    private

    def run_cycle(limit)
      result = Result.new(0, [], [], 0, [])

      begin
        messages = Array(@provider.list_messages(limit))
      rescue StandardError => e
        msg = I18n.t(:error_helpdesk_fetch_failed, :message => e.message)
        Rails.logger.error "Helpdesk (#{@mailbox.mailbox_address}): #{msg}"
        @mailbox.update_columns(:last_error => msg, :last_error_at => Time.current)
        result.errors << { :subject => nil, :error => msg }
        return result
      end

      messages.each_with_index do |meta, i|
        # Maintenance switched on mid-cycle: finish the message at hand, leave
        # the rest in the source folder for the next fetch.
        if i.positive?
          @run&.heartbeat!(i)
          if Maintenance.active?(:fresh => true)
            Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): maintenance mode - " \
                              "stopped after #{i} of #{messages.size} message(s)"
            break
          end
        end

        begin
          process_message(meta, result)
        rescue StandardError => e
          Rails.logger.error "Helpdesk: error processing message #{meta.id} (#{@mailbox.mailbox_address}): #{e.message}"
          result.errors << { :subject => meta.subject, :error => e.message }
          begin
            move_failed(meta.id)
          rescue StandardError => move_err
            Rails.logger.warn "Helpdesk: message #{meta.id} could not be moved to the failed folder: #{move_err.message}"
          end
        end
      end

      if result.errors.any?
        last = result.errors.last
        error_text = last[:subject].present? ? "\"#{last[:subject]}\": #{last[:error]}" : last[:error]
        @mailbox.update_columns(
          :last_fetched_at => Time.current,
          :last_error      => error_text,
          :last_error_at   => Time.current
        )
      else
        @mailbox.update_columns(:last_fetched_at => Time.current, :last_error => nil, :last_error_at => nil)
      end

      result
    end

    def process_message(meta, result)
      sender = meta.from_address.to_s.downcase
      sender_name = meta.from_name.to_s
      subject = meta.subject.to_s

      # Blacklist/whitelist and ignore rules: does the message stay untouched?
      # No - rejected mails are moved too, so they are not re-checked on every fetch.
      if sender_rejected?(sender) || ignore_rule_matches?(subject, sender)
        move_skipped(meta.id)
        result.skipped += 1
        return
      end

      mime = @provider.message_mime(meta.id)

      if auto_reply_filtered?(mime, sender)
        Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): auto-reply ignored – #{subject.inspect} from #{sender}"
        move_skipped(meta.id)
        result.skipped += 1
        return
      end

      # Phishing check against the local feed mirror (per-project toggle).
      # 'quarantine': a mail with a confirmed hit is moved to the skipped folder without a ticket.
      # 'neutralize': links in the body are replaced, processing continues.
      # Suspicious cases (redirect/shortener/link-text mismatch) are only marked,
      # never quarantined (too many legitimate cases, e.g. newsletter tracking).
      phishing_hits = []
      phishing_suspicions = []
      if phishing_check_enabled?
        scan = PhishingScanner.scan(mime)
        if scan[:hits].any? && phishing_action == 'quarantine'
          Rails.logger.warn "Helpdesk (#{@mailbox.mailbox_address}): phishing mail quarantined – " \
                            "#{subject.inspect} from #{sender} (#{scan[:hits].size} URL(s))"
          move_skipped(meta.id)
          result.skipped += 1
          return
        end

        if scan[:hits].any? || scan[:suspicions].any?
          phishing_hits = scan[:hits]
          phishing_suspicions = scan[:suspicions]
          mime = scan[:mime]
          Rails.logger.warn "Helpdesk (#{@mailbox.mailbox_address}): #{phishing_hits.size} phishing URL(s) neutralized, " \
                            "#{phishing_suspicions.size} disguised link(s) marked – #{subject.inspect} from #{sender}"
        end
      end

      # Pre-processing: if the referenced ticket is closed and too old, strip the
      # thread headers so MailHandler creates a new ticket instead.
      mime = maybe_strip_thread_for_new_issue(mime)

      # NDR mails carry Auto-Submitted: auto-replied, which Redmine's MailHandler
      # likewise rejects as an auto-reply. Strip those headers for NDRs.
      mime = strip_auto_submitted_for_ndr(mime)

      # Make sure replies to helpdesk mails land on the right ticket even when the
      # subject has no [#id] tag.
      mime = ensure_thread_reference(mime)

      # Inline images: make sure the body MailHandler keeps still references the
      # embedded images (only needed when Redmine builds the body from the HTML
      # part - see InlineImages). The original MIME stays untouched, it is what
      # gets archived as .eml further down.
      object = MailHandler.receive(InlineImages.prepare_mime(mime), mail_handler_options)

      unless object
        # MailHandler rejected the mail (e.g. own address, invalid input)
        move_skipped(meta.id)
        result.skipped += 1
        return
      end

      issue, new_issue = extract_issue(object)

      if issue
        # MailHandler has saved the embedded images as attachments but left their
        # "[cid:...]" references in the text - point them at those attachments so
        # the ticket shows the pictures instead of the markers.
        InlineImages.rewrite!(object, mime)

        # Signature logos and tracking pixels an agent has blacklisted. After the
        # rewrite, because the markup this removes is the one the rewrite wrote.
        AttachmentBlacklist.filter!(object, issue)

        apply_new_issue_defaults(issue, subject, sender) if new_issue
        reopened = new_issue ? false : apply_reply_status(issue, (object.is_a?(Journal) ? object : nil))
        contact = HelpdeskContact.find_or_create_for(sender, sender_name, @mailbox.project)
        HelpdeskTicketInfo.link!(issue, contact, @mailbox)

        # Mark the ticket as waiting for an agent. Runs after link!, so the
        # HelpdeskTicketInfo row is guaranteed to exist. New tickets are not flagged
        # (they are new work by definition), and neither are mails an agent sent in
        # themselves.
        if !new_issue && HelpdeskTicketInfo.awaiting_agent_enabled? && !agent_authored?(object, issue)
          HelpdeskTicketInfo.mark_awaiting_agent!(
            issue, reopened ? 'reopen' : 'reply', meta.received_at || Time.current
          )
        end

        eml_author = (object.is_a?(Journal) ? object.user : issue.author) || User.anonymous

        parsed_mail = Mail.read_from_string(mime) rescue nil
        msg = HelpdeskMessage.create!(
          :issue             => issue,
          :helpdesk_contact  => contact,
          :helpdesk_mailbox  => @mailbox,
          :direction         => 'in',
          :message_id        => meta.internet_message_id,
          :subject           => subject,
          :sent_at           => meta.received_at,
          :recipient_to      => parsed_mail&.to&.join(', '),
          :recipient_cc      => parsed_mail&.cc&.join(', '),
          :journal_id        => (object.is_a?(Journal) ? object.id : nil)
        )

        eml_att = attach_eml(issue, mime, eml_author)
        if eml_att
          msg.update_column(:eml_attachment_id, eml_att.id)
          # No more HTML in the journal note: Redmine's wiki sanitizer strips
          # class attributes, so styling is impossible. The single-line mail
          # header is injected client-side (_issue_sidebar.html.erb,
          # badge in h4.note-header via timestamp matching).
        end

        send_autoresponder(issue, contact, meta.internet_message_id) if new_issue && @mailbox.autoresponder_enabled?
        if phishing_hits.any? || phishing_suspicions.any?
          add_phishing_note(issue, phishing_hits, phishing_suspicions)
        end
        enqueue_ai_summary(issue, object, new_issue, msg)
        enqueue_completeness_check(issue, msg) if new_issue
        (new_issue ? result.created_issues : result.updated_issues) << issue.id
      end

      move_processed(meta.id)
      result.processed += 1
    end

    # Options for Redmine's MailHandler - the project and the mailbox defaults.
    def mail_handler_options
      issue_attrs = { :project => @mailbox.project.identifier }
      issue_attrs[:tracker]  = @mailbox.default_tracker.name  if @mailbox.default_tracker
      issue_attrs[:priority] = @mailbox.default_priority.name if @mailbox.default_priority
      issue_attrs[:status]   = @mailbox.default_status.name   if @mailbox.default_status

      {
        :issue               => issue_attrs,
        :unknown_user        => @mailbox.unknown_user_mode.presence || 'accept',
        :no_account_notice   => '1',
        :no_permission_check => '1',
        :no_notification     => @mailbox.suppress_notifications? ? '1' : nil
      }.compact
    end

    def extract_issue(object)
      case object
      when Issue   then [object, true]
      when Journal then [object.journalized.is_a?(Issue) ? object.journalized : nil, false]
      else [nil, false]
      end
    end

    # Kicks off the AI summary asynchronously (non-blocking). Checks the global
    # and project-specific activation as well as the scope (first mail only vs.
    # replies too), so no job enters the queue while the feature is off.
    # Enqueue failures must not abort mail processing.
    def enqueue_ai_summary(issue, object, new_issue, msg)
      return unless RedmineExpertHelpdesk::AiFeatures.ai_enabled?

      ps = HelpdeskProjectSetting.for_project(issue.project)
      return unless ps.ai_summary_enabled?
      return if !new_issue && !ps.ai_summary_for_replies?

      HelpdeskAiSummaryJob.perform_later(
        issue.id,
        :journal_id => (object.is_a?(Journal) ? object.id : nil),
        :message_id => msg.id
      )
    rescue => e
      Rails.logger.warn("[helpdesk][ai] enqueue failed (Issue ##{issue.id}): #{e.message}")
    end

    # Enqueue the completeness check of the first mail. New tickets only: a reply in
    # a running conversation must never trigger an automatic follow-up. The cheap
    # switches are checked here already, so no job is queued while the feature is
    # off. An enqueue failure must not abort mail processing.
    def enqueue_completeness_check(issue, msg)
      return unless Setting.plugin_redmine_expert_helpdesk['info_request_enabled'].to_s == '1'
      return unless HelpdeskProjectSetting.for_project(issue.project).info_request_enabled?

      HelpdeskCompletenessJob.perform_later(issue.id, :message_id => msg.id)
    rescue => e
      Rails.logger.warn("[helpdesk][info_request] enqueue failed " \
                        "(Issue ##{issue.id}): #{e.message}")
    end

    # --- Ticket reopen --------------------------------------------------------

    # Strips the thread headers from the MIME message when the referenced ticket is
    # closed AND older than reopen_max_age_days. MailHandler then creates a new
    # ticket instead of appending a comment.
    def maybe_strip_thread_for_new_issue(mime)
      return mime unless @mailbox.reopen_max_age_days.to_i > 0

      msg = Mail.read_from_string(mime)
      issue = find_referenced_issue(msg)
      return mime unless issue&.status&.is_closed?

      age_days = (Time.current.to_f - issue.updated_on.to_f) / 86_400.0
      return mime if age_days <= @mailbox.reopen_max_age_days.to_i

      Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): ticket ##{issue.id} has been closed for #{age_days.round} days " \
                        "(limit: #{@mailbox.reopen_max_age_days} days) – a new ticket will be created"

      msg['in-reply-to'] = nil
      msg['references']  = nil
      msg.subject = msg.subject.to_s.gsub(/\s*\[#\d+\]\s*/, ' ').strip
      msg.to_s
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: thread pre-processing failed: #{e.message}"
      mime
    end

    # Finds the ticket referenced in the subject (pattern [#ID]).
    # Fallback: HelpdeskMessage table via Internet-Message-ID from In-Reply-To.
    def find_referenced_issue(msg)
      if msg.subject.to_s =~ /\[#(\d+)\]/
        issue = Issue.find_by(:id => $1.to_i)
        return issue if issue
      end

      ref_ids = [msg['in-reply-to']&.value.to_s, msg['references']&.value.to_s]
                .join(' ').scan(/<([^>]+)>/).flatten
      if ref_ids.any?
        hm = HelpdeskMessage.where(:message_id => ref_ids).first
        return hm.issue if hm&.issue
      end

      nil
    end

    # Injects [#id] into the subject when the mail is recognised as a reply to a
    # known helpdesk message and the subject has no [#id] tag yet. Keeps the thread
    # assignment working even when the subject was changed or the autoresponder is
    # configured without [#id].
    def ensure_thread_reference(mime)
      msg = Mail.read_from_string(mime)
      return mime if msg.subject.to_s =~ /\[#\d+\]/  # already present

      issue = find_referenced_issue(msg)
      return mime unless issue

      Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): thread reference to ticket ##{issue.id} detected – [##{issue.id}] injected into subject"
      msg.subject = "[##{issue.id}] #{msg.subject}"
      msg.to_s
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: ensure_thread_reference failed: #{e.message}"
      mime
    end

    # Applies the mailbox's configured status for an inbound customer reply. Which
    # status that is depends on the state the ticket is in when the mail arrives:
    # a closed ticket is reopened with reopen_status_id, an open one is moved to
    # open_reply_status_id. The two are separate settings because a helpdesk that keeps
    # a ticket open while it waits for the customer ("waiting for customer") still
    # wants the reply to move it on, and that is not the status a reopened ticket
    # should land in. Either one blank means "leave the ticket's status alone".
    #
    # Returns true only for an actual reopen, meaning a closed ticket that ends up in
    # an open status. The caller labels the awaiting-agent reason from that, and the
    # two cases it deliberately excludes are a status change on an already open
    # ticket, and a reopen status that is itself closed (a mailbox may well point at
    # *Rejected*): neither leaves the ticket open, and TicketStatistics counts a
    # reopen as a closed -> non-closed transition, so calling either one a reopen
    # would label a ticket *Reopened* that the statistics never count.
    #
    # save(validate: false) is deliberate and must stay: the ticket is mutated from
    # arbitrary inbound mail, and a field made mandatory, a workflow transition or a
    # locked version added since the ticket was created would otherwise make the save
    # fail silently -- leaving the ticket closed with the customer's reply inside it.
    #
    # Not resetting the SLA solution time here is deliberate too, and looks like an
    # oversight if you only read this method. Sla.sync_solution! hangs off
    # controller_issues_edit_after_save, so it never fires for this model-level save
    # and info.solution_business_minutes keeps the value from the first close. That
    # is the intended reading: the statistic means "time to first solution". The
    # displayed clock is unaffected -- helpdesk_sla_solution derives "done" from
    # closed?, so it correctly starts running again while the ticket is open -- and
    # a later close through the UI keeps the first value anyway, because
    # sync_solution! returns early once solution_business_minutes is set. Making the
    # reopen reset it would change what the SLA statistics report, so do not "fix"
    # this without deciding that question first.
    def apply_reply_status(issue, journal = nil)
      closed    = issue.status&.is_closed? ? true : false
      status_id = closed ? @mailbox.reopen_status_id : @mailbox.open_reply_status_id
      return false if status_id.blank?

      new_status = IssueStatus.find_by(:id => status_id)
      return false unless new_status
      return false if new_status.id == issue.status_id

      reopened      = closed && !new_status.is_closed?
      old_status_id = issue.status_id
      issue.status = new_status
      issue.save(:validate => false)
      record_reply_status_journal(issue, journal, old_status_id, new_status.id)
      Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): ticket ##{issue.id} " \
                        "#{reopened ? 'reopened' : 'moved to reply status'} \u2013 status \"#{new_status.name}\""
      reopened
    end

    # Makes the automatic status change visible in the ticket history. Because the
    # status is set without init_journal, Redmine writes no journal on its own.
    #
    # Preferred path: attach the status detail to the journal MailHandler just created
    # for the customer reply. That shows one history entry (note + status change)
    # instead of two, and creates no new Journal record -- so it cannot notify anyone.
    # Using issue.init_journal instead would arm Redmine's notification after_save and
    # could send mail, which this feature explicitly must not do.
    def record_reply_status_journal(issue, journal, old_status_id, new_status_id)
      detail = {
        :property => 'attr', :prop_key => 'status_id',
        :old_value => old_status_id.to_s, :value => new_status_id.to_s
      }

      if journal&.persisted?
        JournalDetail.create!(detail.merge(:journal => journal))
      else
        fallback = Journal.new(:journalized => issue, :user => issue.author || User.anonymous)
        fallback.notify = false # Journal#after_create would mail the watchers otherwise
        fallback.details << JournalDetail.new(detail)
        fallback.save!
      end
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: status journal for ticket ##{issue.id} failed: #{e.message}"
    end

    # True when the inbound mail was written by an agent (someone allowed to reply to
    # customers), so their own mail does not flag the ticket as waiting. Uses the same
    # definition of "agent" as the clear path in JournalPatch, which keeps setting and
    # clearing symmetric.
    def agent_authored?(object, issue)
      return false unless object.is_a?(Journal)

      user = object.user
      user.present? && user.allowed_to?(:send_helpdesk_reply, issue.project)
    rescue StandardError
      false
    end

    # --- Auto-reply filter ---------------------------------------------------

    # Checks whether the mail is recognised as an automatically generated
    # message and should be caught by the filter.
    # Returns false when:
    #   - the filter is disabled on the mailbox
    #   - the sender is on the sender whitelist
    #   - a header:value pair from the header whitelist occurs in the mail
    def auto_reply_filtered?(mime, sender)
      return false unless @mailbox.auto_reply_filter_enabled?

      # Sender whitelist: this sender should be processed even with
      # auto-reply headers (e.g. a known monitoring system).
      sender_wl = parse_list(@mailbox.auto_reply_sender_whitelist)
      return false if sender_wl.any? && list_matches?(sender_wl, sender)

      begin
        msg = Mail.read_from_string(mime)
      rescue StandardError => e
        Rails.logger.warn "Helpdesk: mail parsing for the auto-reply check failed: #{e.message}"
        return false
      end

      # NDR detection before the actual auto-reply check.
      # RFC 3462: a delivery status notification always has report-type=delivery-status.
      # Exchange-specific indicators as a fallback.
      if ndr_message?(msg)
        Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): NDR detected, will be processed – CT=#{msg.content_type.inspect}"
        return false
      end

      trigger = auto_reply_trigger(msg)
      return false unless trigger

      Rails.logger.debug "Helpdesk: auto-reply trigger: #{trigger}"

      # Header whitelist: certain header:value pairs lift the filter.
      # Format per line: "Header-Name: Value" or "Header-Name: *" for any value.
      return false if auto_reply_header_whitelist_matches?(msg)

      true
    end

    # Shared with HelpdeskCompletenessJob, which needs the same answer to "did a
    # human write this" for the opposite reason - see AutomatedMail.
    def auto_reply_trigger(msg)
      AutomatedMail.trigger(msg)
    end

    # Detects NDR/DSN messages that should be processed despite auto-reply headers.
    def ndr_message?(msg)
      AutomatedMail.ndr?(msg)
    end

    # Strips Auto-Submitted headers from NDR MIME so Redmine's MailHandler does
    # not ignore the message as an auto-reply.
    def strip_auto_submitted_for_ndr(mime)
      msg = Mail.read_from_string(mime)
      return mime unless ndr_message?(msg)

      msg.header.fields.delete_if { |f| f.name.casecmp('auto-submitted').zero? }
      msg.to_s
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: strip_auto_submitted_for_ndr failed: #{e.message}"
      mime
    end

    # Checks whether an entry from the mailbox's header whitelist occurs in the mail.
    def auto_reply_header_whitelist_matches?(msg)
      parse_list(@mailbox.auto_reply_header_whitelist).any? do |entry|
        if entry.include?(':')
          header_name, expected = entry.split(':', 2).map(&:strip)
          actual = msg[header_name.downcase]&.value.to_s.strip
          expected == '*' ? actual.present? : actual.casecmp(expected).zero?
        else
          msg[entry.downcase.strip]&.value.to_s.present?
        end
      end
    end

    # --- Blacklist/whitelist ------------------------------------------------

    # Entries (one address or domain per line). The whitelist wins: if a whitelist
    # is maintained, only its senders are allowed.
    def sender_rejected?(sender)
      allow = parse_list(@mailbox.allow_list)
      deny  = parse_list(@mailbox.deny_list)

      return true if allow.any? && !list_matches?(allow, sender)
      return true if deny.any? && list_matches?(deny, sender)

      false
    end

    def parse_list(text)
      AutomatedMail.parse_list(text)
    end

    def list_matches?(entries, sender)
      AutomatedMail.list_matches?(entries, sender)
    end

    # --- Rules -----------------------------------------------------------------

    def ignore_rule_matches?(subject, sender)
      @mailbox.helpdesk_rules.where(:action_type => 'ignore').any? do |rule|
        rule.matches?(subject, sender)
      end
    end

    # New tickets only: first the project's default assignee, then the mailbox
    # rules - a matching rule is the more specific statement and may override
    # the default.
    def apply_new_issue_defaults(issue, subject, sender)
      # Reload the ticket so lock_version is current (MailHandler saves the
      # ticket several times, which leads to StaleObjectError when we save the
      # outdated in-memory instance).
      issue.reload
      changed = apply_default_assignee(issue)
      @mailbox.helpdesk_rules.where.not(:action_type => 'ignore').order(:position).each do |rule|
        next unless rule.matches?(subject, sender)

        changed = true if rule.apply_to(issue)
      end
      issue.save(:validate => false) if changed
    end

    # Only when nobody is assigned yet: MailHandler may already have honoured an
    # "Assigned to:" keyword from the mail, and that wins over the project default.
    def apply_default_assignee(issue)
      return false if issue.assigned_to_id.present?

      assignee = project_setting.default_assignee
      return false unless assignee

      issue.assigned_to = assignee
      true
    end

    # --- Phishing check -------------------------------------------------------

    # Active when: enabled globally + enabled in the project + mirror not empty.
    # Logs the reason when the check is skipped.
    def phishing_check_enabled?
      unless Setting.plugin_redmine_expert_helpdesk['phishtank_enabled'] == '1'
        Rails.logger.info "Helpdesk/Phishing (#{@mailbox.mailbox_address}): check skipped – disabled globally"
        return false
      end
      unless project_setting.phishing_check_enabled?
        Rails.logger.info "Helpdesk/Phishing (#{@mailbox.mailbox_address}): check skipped – disabled in project '#{@mailbox.project.identifier}'"
        return false
      end
      unless HelpdeskPhishingUrl.exists?
        Rails.logger.warn "Helpdesk/Phishing (#{@mailbox.mailbox_address}): check skipped – PhishTank mirror is empty"
        return false
      end

      Rails.logger.info "Helpdesk/Phishing (#{@mailbox.mailbox_address}): check active (action: #{phishing_action})"
      true
    end

    def phishing_action
      project_setting.effective_phishing_action
    end

    def project_setting
      @project_setting ||= HelpdeskProjectSetting.for_project(@mailbox.project)
    end

    # Internal note on the ticket: which phishing URLs were neutralized and which
    # disguised links were marked.
    def add_phishing_note(issue, hits, suspicions = [])
      sections = []

      if hits.any?
        lines = hits.map do |h|
          detail = h[:target].present? ? " (Ziel: #{h[:target]})" : ''
          resolved = h[:resolved_url].present? ? " -> #{h[:resolved_url]}" : ''
          "* #{h[:url]}#{resolved} – #{h[:source_label]}#{detail}"
        end
        sections << "#{I18n.t(:note_helpdesk_phishing_links_removed, :count => hits.size)}\n\n#{lines.join("\n")}"
      end

      if suspicions.any?
        lines = suspicions.map { |s| "* #{s[:url]} – #{s[:label]}" }
        sections << "#{I18n.t(:note_helpdesk_phishing_suspicions, :count => suspicions.size)}\n\n#{lines.join("\n")}"
      end

      Journal.create!(
        :journalized   => issue,
        :user          => User.anonymous,
        :notes         => sections.join("\n\n"),
        :private_notes => false
      )
    rescue StandardError => e
      Rails.logger.error "Helpdesk: phishing note for ticket ##{issue.id} failed: #{e.message}"
    end

    # --- Autoresponder --------------------------------------------------------

    def send_autoresponder(issue, contact, in_reply_to_message_id = nil)
      body = TemplateRenderer.render(@mailbox.autoresponder_body, :issue => issue, :contact => contact)
      subject = TemplateRenderer.render(
        @mailbox.autoresponder_subject.presence || "[##{issue.id}] {{ticket_subject}}",
        :issue => issue, :contact => contact
      )

      # Build the MIME so In-Reply-To / References can be set.
      # Microsoft Graph rejects these headers on JSON requests (sendMail) with HTTP 400.
      # Via the References link to the original customer mail, Redmine's MailHandler
      # recognises replies to the autoresponder and assigns them to the ticket.
      mail = Mail.new
      mail.from    = @mailbox.from_address
      # Opt-in only; see HelpdeskMailbox#reply_to_address.
      reply_to_addr = @mailbox.reply_to_address
      mail.reply_to = reply_to_addr if reply_to_addr
      mail.to      = contact.email
      mail.subject = subject
      mail.body    = body

      if in_reply_to_message_id.present?
        ref_id = "<#{in_reply_to_message_id.to_s.delete('<>').strip}>"
        mail['In-Reply-To'] = ref_id
        mail['References']  = ref_id
      end

      MailLogger.track(
        :kind => 'autoresponder', :mailbox => @mailbox, :issue => issue,
        :to => contact.email, :subject => subject, :message_id => mail.message_id
      ) { deliver_autoresponder(mail) }

      HelpdeskMessage.create!(
        :issue => issue, :helpdesk_contact => contact, :helpdesk_mailbox => @mailbox,
        :direction => 'out', :subject => subject, :sent_at => Time.current
      )

      # Internal note: record the autoresponder send in the ticket journal
      Journal.create!(
        :journalized   => issue,
        :user          => User.anonymous,
        :notes         => I18n.t(:note_helpdesk_autoresponder_sent, :email => contact.email),
        :private_notes => false
      )
    rescue MailProvider::ProviderError => e
      Rails.logger.error "Helpdesk: autoresponder for ticket ##{issue.id} failed: #{e.message}"
    end

    # The autoresponder takes the mailbox's outgoing route like every other
    # outgoing mail: 'smtp' hands the message to Redmine's own ActionMailer
    # configuration, everything else goes through a provider.
    def deliver_autoresponder(mail)
      if @mailbox.outgoing_route == 'smtp'
        mail.delivery_method(ActionMailer::Base.delivery_method,
                             ActionMailer::Base.smtp_settings || {})
        mail.deliver!
        # Redmine's relay files nothing in the mailbox, so archive it ourselves.
        @provider.archive_sent(mail.to_s)
      else
        autoresponder_provider.send_mail_mime(mail.to_s)
      end
    end

    # Reuse the injected fetch provider where it is also the sender, so tests can
    # keep driving the whole cycle through one double.
    def autoresponder_provider
      return @provider if @mailbox.outgoing_route == 'mailbox_smtp'

      MailProvider.outgoing_for(@mailbox)
    end

    def move_processed(message_id)
      @provider.mark_as_read(message_id)
      return if @mailbox.processed_folder.blank?

      @provider.move_message(message_id, @mailbox.processed_folder)
    end

    # Moves skipped mails (blacklist, ignore rule, auto-reply) into the
    # configured folder. Fallback: processed_folder.
    def move_skipped(message_id)
      @provider.mark_as_read(message_id)
      target = @mailbox.skipped_folder.presence || @mailbox.processed_folder.presence
      return if target.blank?

      @provider.move_message(message_id, target)
    end

    # Moves failed mails (exception during processing) into the configured folder.
    # Fallback: processed_folder.
    def move_failed(message_id)
      @provider.mark_as_read(message_id)
      target = @mailbox.failed_folder.presence || @mailbox.processed_folder.presence
      return if target.blank?

      @provider.move_message(message_id, target)
    end

    # Attaches the original mail to the ticket as an .eml file.
    # Uses StringIO to avoid Tempfile lifetime problems.
    # Returns the stored attachment object, or nil on error.
    def attach_eml(issue, mime, author)
      filename = "original_mail_#{Time.current.strftime('%Y%m%d_%H%M%S')}.eml"

      # Make sure the bytes are stored unchanged as binary
      raw = mime.dup.force_encoding('BINARY')
      io  = StringIO.new(raw)
      io.define_singleton_method(:original_filename) { filename }
      io.define_singleton_method(:content_type)      { 'application/octet-stream' }

      att = Attachment.new(
        :container   => issue,
        :file        => io,
        :description => 'Original E-Mail',
        :author      => author
      )
      att.save!
      att
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: EML attachment for ticket ##{issue.id} failed: #{e.message}\n#{e.backtrace.first(3).join('\n')}"
      nil
    end
  end
end

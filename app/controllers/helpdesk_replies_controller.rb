require 'base64'

# Reply to the customer directly from the ticket.
# The reply is wrapped with the mailbox's header/footer template, sent via
# Graph sendMail from the project mailbox, and additionally documented as a
# comment (journal) on the ticket.
class HelpdeskRepliesController < ApplicationController
  before_action :find_issue
  before_action :authorize_reply

  def create
    info    = HelpdeskTicketInfo.for_issue(@issue)
    mailbox = info&.helpdesk_mailbox&.enabled? ? info.helpdesk_mailbox : nil
    mailbox ||= @project.helpdesk_mailboxes.enabled.first

    contact = info&.helpdesk_contact

    if mailbox.nil? || contact.nil?
      render :json => { :success => false, :error => l(:error_helpdesk_no_recipient) },
             :status => :unprocessable_entity
      return
    end

    # Note content (wiki markup) from the Redmine note field
    note = params[:note_content].to_s
    if note.strip.blank?
      render :json => { :success => false, :error => l(:error_helpdesk_empty_reply) },
             :status => :unprocessable_entity
      return
    end

    # The customer stands in for an empty To - but only after the hand-over
    # targets were taken from what the agent actually typed. Filling it in
    # first would hand over to the contact itself when that is a participating
    # mailbox, a project the agent never named.
    typed_to  = params[:reply_to].to_s.strip
    reply_to  = params.key?(:reply_to) ? typed_to : contact.email
    reply_cc  = params[:reply_cc].to_s.strip.gsub(/[\s,;]+\z/, '')
    reply_bcc = params[:reply_bcc].to_s.strip.gsub(/[\s,;]+\z/, '')

    # Experimental hand-over: helpdesk addresses of participating projects are
    # taken out of the mail and get the ticket directly (see Handover).
    targets   = RedmineExpertHelpdesk::Handover.targets_for(@project)
    handovers = []
    bcc_only  = []
    if targets.any?
      reply_to,  hits_to  = RedmineExpertHelpdesk::Handover.split(reply_to, targets)
      reply_cc,  hits_cc  = RedmineExpertHelpdesk::Handover.split(reply_cc, targets)
      reply_bcc, hits_bcc = RedmineExpertHelpdesk::Handover.split(reply_bcc, targets)
      # One ticket per project: two of its mailboxes in To and Cc are still
      # one hand-over, and the first one named supplies the defaults.
      handovers = (hits_to + hits_cc + hits_bcc).uniq(&:project_id)
      # Projects named in Bcc only: the form must not name them in a public
      # note, or every reader learns about a recipient the mail kept blind.
      bcc_only  = hits_bcc.map(&:project_id) - (hits_to + hits_cc).map(&:project_id)
      # A To the agent cleared on purpose stays empty: the customer fallback
      # above would otherwise mail them a reply meant only for the other
      # project. Without a hand-over the fallback stays, so a reply never ends
      # up going nowhere.
    end
    # A To cleared on purpose stays empty when something is handed over: the
    # fallback would mail the customer a reply meant only for the other
    # project. Without a hand-over it stays, so a reply never goes nowhere.
    reply_to = contact.email if typed_to.empty? && handovers.empty? && reply_to.blank?
    handover_mode = params[:handover_mode].to_s
    if handovers.any? && !RedmineExpertHelpdesk::Handover::MODES.include?(handover_mode)
      render :json => { :success => false, :error => l(:error_helpdesk_handover_mode_missing) },
             :status => :unprocessable_entity
      return
    end
    # A hand-over copies the ticket's text and files into another project, so
    # the agent has to be able to read the ticket - send_helpdesk_reply is a
    # project permission and says nothing about "own tickets only" roles.
    if handovers.any? && !@issue.visible?
      render :json => { :success => false, :error => l(:notice_not_authorized) }, :status => :forbidden
      return
    end
    # A mail needs a To: with only Cc left, the Cc becomes the To. Only Bcc
    # left is refused - promoting it would show the Bcc recipients to each
    # other, and a mail without any To is not delivered the same way by every
    # transport. Checked before anything is handed over.
    reply_to, reply_cc = reply_cc, '' if reply_to.blank? && reply_cc.present?
    if reply_to.blank? && reply_bcc.present?
      render :json => { :success => false, :error => l(:error_helpdesk_handover_bcc_only) },
             :status => :unprocessable_entity
      return
    end
    send_mail = reply_to.present?

    # Subject from the project settings with macro evaluation
    project_setting  = HelpdeskProjectSetting.for_project(@project)
    subject_template = project_setting.effective_subject_template
    context = { :issue => @issue, :contact => contact, :user => User.current }
    subject = RedmineExpertHelpdesk::TemplateRenderer.render(subject_template, context)

    # Wiki markup → HTML for the e-mail body
    wiki_html = begin
      Redmine::WikiFormatting.formatter.new(note).to_html.to_s
    rescue StandardError
      "<p>#{ERB::Util.html_escape(note)}</p>"
    end

    header_html = plain_to_html(RedmineExpertHelpdesk::TemplateRenderer.render(mailbox.reply_header.to_s, context))
    footer_html = plain_to_html(RedmineExpertHelpdesk::TemplateRenderer.render(mailbox.effective_footer_template, context))
    body_html = [header_html, wiki_html, footer_html].reject(&:blank?).join("\n")

    # Attachments: only allow IDs that actually belong to the ticket
    attachment_ids = Array(params[:attachment_ids]).map(&:to_i).reject(&:zero?)
    sent_filenames = []
    valid_att_ids  = attachment_ids.any? ? (attachment_ids & @issue.attachments.pluck(:id)) : []

    # Pending attachments by token: everything the agent uploaded through the
    # standard attachment field (or pasted into the note) while editing, not
    # yet attached to the ticket - the issue form only saves them on submit,
    # which happens after the mail is sent. Resolved here so they go out with
    # the reply. Author check: the uploader is the only one who may send it.
    inline_tokens = Array(params[:inline_attachment_tokens]).map(&:to_s).reject(&:blank?).first(20)
    inline_atts   = inline_tokens.filter_map { |tok| Attachment.find_by_token(tok) }
                                 .select { |a| a.author_id == User.current.id }

    # The hand-over runs before the mail, so a failed mail can take it back
    # (rescue below) instead of leaving a ticket nobody was told about. Its
    # notification waits until the mail is out (finish_handovers) - a mail
    # already sent about a ticket that is then deleted cannot be taken back.
    # Ticket images the note quotes go along like the checked files: the
    # customer gets them embedded, the other team needs them just as much.
    created = []
    if handovers.any?
      quoted = RedmineExpertHelpdesk::ReplyImages.to_cid(
        wiki_html, RedmineExpertHelpdesk::ReplyImages.candidates(@issue, inline_atts)
      ).first.keys
      handover_atts = (Attachment.where(:id => valid_att_ids).to_a + inline_atts + quoted).uniq
      handovers.each do |target|
        created << RedmineExpertHelpdesk::Handover.new(
          :source => @issue, :mailbox => target, :user => User.current, :mode => handover_mode,
          :note => note, :attachments => handover_atts, :contact => contact,
          :bcc => bcc_only.include?(target.project_id), :ai_drafted => params[:hd_ai_drafted].to_s == '1'
        ).call
      end
    end
    handover_json = created.zip(handovers).map do |i, target|
      { :issue_id => i.id, :address => target.mailbox_address,
        :project  => (i.project.visible? ? i.project.name : nil),
        :bcc      => bcc_only.include?(target.project_id) }
    end

    unless send_mail
      finish_handovers(created, handovers)
      render :json => { :success => true, :helpdesk_message_id => nil, :handovers => handover_json }
      return
    end

    message_id = nil
    delivered  = false

    # Inline image candidates: freshly inserted uploads AND the ticket's own
    # image attachments — a quote of the original mail refers to the latter.
    image_atts = RedmineExpertHelpdesk::ReplyImages.candidates(@issue, inline_atts)

    if mailbox.outgoing_route == 'smtp'
      processed_html, embedded_atts = RedmineExpertHelpdesk::ReplyImages.to_data_uri(body_html, image_atts)
      # Every pending upload rides along as a file attachment, minus the ones
      # the body embeds inline - an image referenced by the text is sent once
      # (as a data URI), not twice.
      embedded_ids = embedded_atts.map(&:id).reject(&:nil?)
      regular_ids  = (valid_att_ids + inline_atts.map(&:id)).uniq - embedded_ids
      message_id = send_reply_smtp(mailbox, reply_to, reply_cc, reply_bcc, subject, processed_html,
                                   regular_ids, embedded_atts, sent_filenames)
      delivered = true
    else
      # Raw MIME delivery for reliable CID inline images – both via the Graph
      # API and via the mailbox's own SMTP server. The JSON approach does not
      # work because Exchange rewrites the HTML before delivery and in doing so
      # separates cid: references from isInline attachments. With
      # Content-Type: text/plain + base64 MIME the MIME structure is preserved.
      message_id             = generate_message_id(mailbox.mailbox_address)
      regular_atts           = Attachment.where(:id => valid_att_ids).to_a
      cid_map, html_with_cid = RedmineExpertHelpdesk::ReplyImages.to_cid(body_html, image_atts)
      # Same rule as the SMTP branch above: pending uploads become regular
      # parts, inline-embedded images are not attached as files a second time.
      regular_atts = (regular_atts + inline_atts).uniq { |a| a.id } - cid_map.keys
      mime_msg = build_cid_mime(mailbox.mailbox_address, reply_to, reply_cc, reply_bcc,
                                subject, html_with_cid, cid_map, regular_atts, message_id)
      RedmineExpertHelpdesk::MailLogger.track(
        :kind => 'reply', :mailbox => mailbox, :issue => @issue,
        :to => reply_to, :cc => reply_cc, :bcc => reply_bcc,
        :subject => subject, :message_id => message_id
      ) do
        RedmineExpertHelpdesk::MailProvider.outgoing_for(mailbox).send_mail_mime(mime_msg)
      end
      delivered = true
      sent_filenames.concat(regular_atts.map(&:filename))
      sent_filenames.concat(cid_map.keys.map(&:filename))
    end
    finish_handovers(created, handovers)

    hd_msg = HelpdeskMessage.create!(
      :issue             => @issue,
      :helpdesk_contact  => contact,
      :helpdesk_mailbox  => mailbox,
      :direction         => 'out',
      :message_id        => message_id,
      :subject           => subject,
      :sent_at           => Time.current,
      :recipient_to      => reply_to,
      :recipient_cc      => reply_cc.presence,
      :recipient_bcc     => reply_bcc.presence,
      :sent_attachments  => sent_filenames.join(', ').presence,
      # The text came from an AI answer draft - even if the agent revised it.
      # KnowledgeExtractor later excludes such answers, so the model does not
      # read its own output back in as truth.
      :ai_drafted        => params[:hd_ai_drafted].to_s == '1'
    )

    # Return the ID: the form sends it along with the issue update as a hidden
    # field, and the controller_issues_edit_after_save hook then links the journal.
    # SLA: a customer reply stops the reaction clock.
    RedmineExpertHelpdesk::Sla.record_first_response!(@issue, Time.current, :by => User.current)

    render :json => { :success => true, :helpdesk_message_id => hd_msg.id, :handovers => handover_json }
  rescue RedmineExpertHelpdesk::MailProvider::ProviderError => e
    render :json => { :success => false, :error => failed_with(e, undo_handovers(created, handovers)) },
           :status => :unprocessable_entity
  rescue StandardError => e
    # Once the mail is out, the hand-over stays: that mail left the other
    # project's address out, so removing its ticket would leave the team with
    # nothing. Reported as sent - an error would invite a second, duplicate mail.
    if delivered
      finish_handovers(created, handovers) unless @handovers_finished
      Rails.logger.error "Helpdesk reply on ##{@issue.id}: delivered, but recording it failed: #{e.class}: #{e.message}"
      render :json => { :success => true, :helpdesk_message_id => hd_msg&.id, :handovers => handover_json,
                        :warning => l(:warning_helpdesk_reply_not_recorded) }
      return
    end
    render :json => { :success => false, :error => failed_with(e, undo_handovers(created, handovers)) },
           :status => :unprocessable_entity
  end

  private

  # Notifies the target projects once the hand-overs are final.
  def finish_handovers(issues, mailboxes)
    @handovers_finished = true
    Array(issues).zip(Array(mailboxes)).each do |issue, mailbox|
      RedmineExpertHelpdesk::Handover.finalize(issue, mailbox)
    end
  end

  # The agent sees an error and sends again, so a hand-over that went through
  # before the mail failed would otherwise be created twice. A ticket the
  # other team has already worked on stays (Handover.undo) and is final now;
  # returns those as [ticket, mailbox] pairs for the error message.
  def undo_handovers(issues, mailboxes)
    kept = Array(issues).zip(Array(mailboxes)).reject do |issue, _|
      RedmineExpertHelpdesk::Handover.undo(issue)
    rescue StandardError => e
      Rails.logger.error "Helpdesk handover: ##{issue.id} could not be removed after a failed send: #{e.message}"
      false
    end
    finish_handovers(kept.map(&:first), kept.map(&:last)) if kept.any?
    kept
  end

  # The error, and the hand-overs that stay - so the agent leaves their
  # addresses out when sending again.
  def failed_with(error, kept)
    return error.message if kept.empty?

    "#{error.message} #{l(:text_helpdesk_handover_kept_after_failure,
                          :targets => RedmineExpertHelpdesk::InitMailer.handover_list(kept))}"
  end

  def build_recipients(addresses_str)
    addresses_str.to_s.split(/[,;]+/).map(&:strip).reject(&:blank?).map do |addr|
      { 'emailAddress' => { 'address' => addr } }
    end
  end

  # Converts simple plain text into minimal HTML (for header/footer templates).
  def plain_to_html(text)
    return '' if text.blank?
    return text if text.include?('<') && text.include?('>')
    '<p>' + ERB::Util.html_escape(text).gsub(/\n{2,}/, '</p><p>').gsub("\n", '<br>') + '</p>'
  end

  # Sends the reply via Redmine's configured SMTP transport.
  # Returns the message ID of the sent mail.
  def send_reply_smtp(mailbox, to, cc, bcc, subject, body_html, att_ids, embedded_atts, sent_filenames)
    mail_obj             = Mail.new
    mail_obj.message_id  = generate_message_id(mailbox.mailbox_address)
    mail_obj.from    = mailbox.from_address
    # Opt-in only; see HelpdeskMailbox#reply_to_address.
    reply_to_addr = mailbox.reply_to_address
    mail_obj.reply_to = reply_to_addr if reply_to_addr
    mail_obj.to      = to
    mail_obj.cc      = cc  if cc.present?
    mail_obj.bcc     = bcc if bcc.present?
    mail_obj.subject = subject

    all_file_atts = Attachment.where(:id => att_ids).to_a + Array(embedded_atts)

    if all_file_atts.any?
      mail_obj.html_part do
        content_type 'text/html; charset=UTF-8'
        body body_html
      end
      all_file_atts.each do |att|
        sent_filenames << att.filename
        mail_obj.add_file(:filename => att.filename,
                          :content  => File.binread(att.diskfile))
      end
    else
      mail_obj.content_type = 'text/html; charset=UTF-8'
      mail_obj.body = body_html
    end

    delivery_method = ActionMailer::Base.delivery_method
    smtp_settings   = ActionMailer::Base.smtp_settings || {}
    mail_obj.delivery_method(delivery_method, smtp_settings)
    RedmineExpertHelpdesk::MailLogger.track(
      :kind => 'reply', :mailbox => mailbox, :issue => @issue,
      :to => to, :cc => cc, :bcc => bcc, :subject => subject,
      :message_id => mail_obj.message_id, :detail => "delivery_method=#{delivery_method}"
    ) { mail_obj.deliver! }
    # Redmine's relay files nothing in the mailbox itself; for an IMAP mailbox we
    # can still put the copy where the agents look. No-op for Graph mailboxes.
    RedmineExpertHelpdesk::MailProvider.for(mailbox).archive_sent(mail_obj.to_s)
    mail_obj.message_id
  end

  # Builds a complete RFC 2822 MIME message with CID inline images.
  # The message is then sent via the Graph API MIME endpoint
  # (Content-Type: text/plain, body: Base64 of the MIME message).
  def build_cid_mime(from, to, cc, bcc, subject, body_html, cid_map, regular_atts, message_id = nil)
    bnd_mixed   = "mix#{SecureRandom.hex(10)}"
    bnd_related = "rel#{SecureRandom.hex(10)}"
    has_inline  = cid_map.any?
    has_regular = regular_atts.reject { |a| !a.diskfile || !File.exist?(a.diskfile) }.any?

    ln = []
    ln << "MIME-Version: 1.0"
    ln << "Message-ID: #{message_id}" if message_id.present?
    ln << "From: #{from}"
    ln << "To: #{to}"
    ln << "Cc: #{cc}"   if cc.present?
    ln << "Bcc: #{bcc}" if bcc.present?
    ln << "Subject: #{mime_encode_subject(subject)}"

    if !has_inline && !has_regular
      ln << "Content-Type: text/html; charset=\"UTF-8\""
      ln << "Content-Transfer-Encoding: base64"
      ln << ""
      ln << mime_base64(body_html)
      return ln.join("\r\n")
    end

    if has_inline && has_regular
      ln << "Content-Type: multipart/mixed; boundary=\"#{bnd_mixed}\""
      ln << ""
      ln << "--#{bnd_mixed}"
      ln << "Content-Type: multipart/related; type=\"text/html\"; boundary=\"#{bnd_related}\""
      ln << ""
      ln << "--#{bnd_related}"
    elsif has_inline
      ln << "Content-Type: multipart/related; type=\"text/html\"; boundary=\"#{bnd_related}\""
      ln << ""
      ln << "--#{bnd_related}"
    else
      ln << "Content-Type: multipart/mixed; boundary=\"#{bnd_mixed}\""
      ln << ""
      ln << "--#{bnd_mixed}"
    end

    # HTML part
    ln << "Content-Type: text/html; charset=\"UTF-8\""
    ln << "Content-Transfer-Encoding: base64"
    ln << ""
    ln << mime_base64(body_html)

    if has_inline
      cid_map.each do |att, cid|
        next unless att.diskfile && File.exist?(att.diskfile)
        mt = att.content_type.presence ||
             Redmine::MimeType.of(att.filename) || 'application/octet-stream'
        ln << ""
        ln << "--#{bnd_related}"
        ln << "Content-Type: #{mt}"
        ln << "Content-Transfer-Encoding: base64"
        ln << "Content-ID: <#{cid}>"
        ln << "Content-Disposition: inline; filename=\"#{att.filename}\""
        ln << ""
        ln << mime_base64(File.binread(att.diskfile))
      end
      ln << ""
      ln << "--#{bnd_related}--"
    end

    if has_regular
      regular_atts.each do |att|
        next unless att.diskfile && File.exist?(att.diskfile)
        mt = att.content_type.presence || 'application/octet-stream'
        ln << ""
        ln << "--#{bnd_mixed}"
        ln << "Content-Type: #{mt}; name=\"#{att.filename}\""
        ln << "Content-Transfer-Encoding: base64"
        ln << "Content-Disposition: attachment; filename=\"#{att.filename}\""
        ln << ""
        ln << mime_base64(File.binread(att.diskfile))
      end
      ln << ""
      ln << "--#{bnd_mixed}--"
    end

    ln.join("\r\n")
  end

  # Base64-encodes a string for MIME (line break every 76 characters, CRLF).
  def mime_base64(data)
    raw = data.dup.force_encoding('BINARY')
    Base64.encode64(raw).gsub(/\r?\n/, "\r\n").chomp
  end

  # RFC 2047-encodes the e-mail subject when it contains non-ASCII characters.
  def mime_encode_subject(str)
    str.ascii_only? ? str : "=?UTF-8?B?#{Base64.strict_encode64(str.encode('UTF-8'))}?="
  end

  # Generates a unique RFC 2822 message ID.
  def generate_message_id(from_address)
    domain = from_address.to_s.split('@').last.presence || 'helpdesk.local'
    "<#{SecureRandom.uuid}@#{domain}>"
  end

  def find_issue
    @issue = Issue.find(params[:issue_id])
    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_reply
    deny_access unless User.current.allowed_to?(:send_helpdesk_reply, @project)
  end
end

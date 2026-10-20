# View hooks: customer card in the sidebar, info bar at the top of the ticket and reply form
module RedmineExpertHelpdesk
  class Hooks < Redmine::Hook::ViewListener
    # Insert the stylesheet for activity feed icons (incoming/outgoing/first contact) into the <head>.
    # From Redmine 6 on, additionally provide a JS helper that generates SVG sprite icons
    # (the old `icon icon-*` CSS classes were removed in Redmine 7). This way, elements
    # created via JavaScript (reply button, sidebar) can display icons correctly too.
    def view_layouts_base_html_head(context = {})
      out = stylesheet_link_tag('helpdesk_activity', :plugin => 'redmine_expert_helpdesk')
      # Disclosure toggle of the recipients pill (_recipients_pill). Delegated on
      # document, because the journal pills are injected after page load. Enter
      # and Space arrive as click on a <button>; Escape and an outside click close.
      out << javascript_tag(<<~JS)
        (function(){
          function setOpen(w,o){w.classList.toggle('open',o);w.querySelector('.hd-rcpt-pill').setAttribute('aria-expanded',o?'true':'false');}
          function closeAll(except){document.querySelectorAll('.hd-rcpt.open').forEach(function(w){if(w!==except)setOpen(w,false);});}
          document.addEventListener('click',function(e){
            var b=e.target.closest&&e.target.closest('.hd-rcpt-pill');
            if(!b){if(!(e.target.closest&&e.target.closest('.hd-rcpt-pop')))closeAll(null);return;}
            var w=b.parentNode;closeAll(w);setOpen(w,!w.classList.contains('open'));
          });
          document.addEventListener('keydown',function(e){
            if(e.key!=='Escape')return;
            var w=document.querySelector('.hd-rcpt.open');if(!w)return;
            setOpen(w,false);w.querySelector('.hd-rcpt-pill').focus();
          });
        })();
      JS
      if Redmine::VERSION::MAJOR >= 6
        sprite = asset_path('icons.svg')
        out << javascript_tag(
          "window.hdIconsSprite=#{sprite.to_json};" \
          "window.hdSpriteIcon=function(n){return '<svg class=\"s18 icon-svg\" aria-hidden=\"true\">'+" \
          "'<use href=\"'+window.hdIconsSprite+'#icon--'+n+'\"></use></svg>';};"
        )
      end
      out
    end

    # Info bar at the top of the ticket (below the fields, no Deface required).
    # view_issues_show_details_bottom is rendered inside <div class="attributes">.
    # Shows contact info even when the first ticket was outbound (manually assigned).
    def view_issues_show_details_bottom(context = {})
      issue = context[:issue]
      return '' unless issue

      project = issue.project
      return '' unless project.module_enabled?(:helpdesk)

      # Attachment blacklist button: its own permission, so it is emitted before
      # the view_helpdesk_info gate below rather than inside it.
      parts = [attachment_blacklist_assets(issue, project)]

      return parts.join.html_safe unless User.current.allowed_to?(:view_helpdesk_info, project)

      # SLA box (independent of the customer contact)
      sla_state = RedmineExpertHelpdesk::Sla.state_for(issue)
      if sla_state && (sla_state[:reaction] || sla_state[:solution])
        parts << context[:controller].send(:render_to_string, {
          :partial => 'helpdesk/sla_box',
          :locals  => { :sla_state => sla_state }
        })
      end

      contact = HelpdeskTicketInfo.for_issue(issue)&.helpdesk_contact
      if contact
        # inbound is nil when no inbound ticket exists (manual/outbound)
        inbound = HelpdeskMessage.incoming.includes(:eml_attachment, :helpdesk_mailbox)
                                 .where(:issue_id => issue.id)
                                 .order(:id => :asc).first

        # Outbound first contact ("New Helpdesk Ticket"): show the initial mail
        outbound = nil
        if inbound.nil?
          outbound = HelpdeskMessage.where(:issue_id => issue.id, :direction => %w[out init])
                                    .order(:id => :asc).first
        end

        # The "never ask this customer" toggle is only offered while the
        # completeness check can actually run here; the marker on an already
        # flagged customer is shown either way.
        info_request_active =
          Setting.plugin_redmine_expert_helpdesk['info_request_enabled'].to_s == '1' &&
          HelpdeskProjectSetting.for_project(issue.project).info_request_enabled?

        parts << context[:controller].send(:render_to_string, {
          :partial => 'helpdesk/issue_header_bar',
          :locals  => {
            :issue               => issue,
            :inbound             => inbound,
            :outbound            => outbound,
            :contact             => contact,
            :info_request_active => info_request_active
          }
        })
      end

      parts.join.html_safe
    end

    # Customer card in the ticket sidebar (after the saved queries)
    # Runs on the issue show page AND the issue list;
    # the guard on @issue ensures that only the show page is rendered.
    # Shows contact info also for manually/outbound assigned tickets.
    def view_issues_sidebar_queries_bottom(context = {})
      issue = context[:controller]&.instance_variable_get(:@issue)
      # Without @issue it is the ticket list: show the "awaiting agent" counter
      # there. Rendered once per page (not per row), one COUNT is enough.
      return awaiting_agent_counter(context) unless issue

      project = issue.project
      return '' unless project.module_enabled?(:helpdesk)

      contact = HelpdeskTicketInfo.for_issue(issue)&.helpdesk_contact

      if contact.nil?
        # No contact: show the assignment form in the sidebar
        return '' unless User.current.allowed_to?(:send_helpdesk_reply, project)
        mailboxes = project.helpdesk_mailboxes.enabled.to_a
        return '' if mailboxes.empty?
        return context[:controller].send(:render_to_string, {
          :partial => 'helpdesk/init_section',
          :locals  => {
            :issue            => issue,
            :project          => project,
            :mailboxes        => mailboxes,
            :in_new_form      => false,
            :values           => {},
            :handover_targets => handover_targets(project)
          }
        })
      end

      # Contact exists: show the customer card
      return '' unless User.current.allowed_to?(:view_helpdesk_info, project)

      outgoing_msgs = HelpdeskMessage.outgoing
                                     .where(:issue_id => issue.id)
                                     .where.not(:recipient_to => [nil, ''])
                                     .select(:id, :journal_id, :sent_at, :recipient_to, :recipient_cc, :recipient_bcc, :sent_attachments)

      context[:controller].send(:render_to_string, {
        :partial => 'helpdesk/issue_sidebar',
        :locals  => {
          :issue         => issue,
          :contact       => contact,
          :project       => project,
          :outgoing_msgs => outgoing_msgs
        }
      })
    end

    # Additions to the edit form: the toolbar (quoting and answer templates)
    # and below it the reply form. The toolbar does not depend on a customer
    # contact — quoting the conversation is exactly what you do before one is
    # linked.
    def view_issues_edit_notes_bottom(context = {})
      issue = context[:issue]
      project = issue.project
      return '' unless project.module_enabled?(:helpdesk)
      return '' unless User.current.allowed_to?(:send_helpdesk_reply, project)

      info    = HelpdeskTicketInfo.for_issue(issue)
      contact = info&.helpdesk_contact

      parts = [note_toolbar(context, issue, project, contact)]
      parts << reply_form(context, issue, project, info, contact) if contact
      parts.join.html_safe
    end

    # "Create Helpdesk Ticket" section in the new ticket form.
    # Enables sending an initial mail directly when creating the ticket.
    def view_issues_form_details_bottom(context = {})
      issue = context[:issue]
      return '' unless issue.new_record?

      project = issue.project
      return '' unless project&.module_enabled?(:helpdesk)
      return '' unless User.current.allowed_to?(:send_helpdesk_reply, project)

      mailboxes = project.helpdesk_mailboxes.enabled.to_a
      return '' if mailboxes.empty?

      context[:controller].send(:render_to_string, {
        :partial => 'helpdesk/init_section',
        :locals  => {
          :issue            => issue,
          :project          => project,
          :mailboxes        => mailboxes,
          :in_new_form      => true,
          :values           => init_values(context),
          :handover_targets => handover_targets(project)
        }
      })
    end

    # Controller hook: links the customer contact and optionally sends an initial mail after
    # a new ticket is created, when helpdesk_init parameters were passed.
    def controller_issues_new_after_save(context = {})
      issue  = context[:issue]
      params = context[:params]

      hd = params[:helpdesk_init]
      return unless hd.present?
      return unless issue.project.module_enabled?(:helpdesk)
      return unless User.current.allowed_to?(:send_helpdesk_reply, issue.project)

      send_mail = hd[:send_mail] == '1'
      # Mail switched off and nobody named: nothing was asked for.
      return if !send_mail && hd[:contact_email].to_s.strip.empty?

      mailbox = issue.project.helpdesk_mailboxes.enabled.find_by(:id => hd[:mailbox_id].to_i) ||
                issue.project.helpdesk_mailboxes.enabled.first
      return unless mailbox

      RedmineExpertHelpdesk::InitMailer.call(
        :issue         => issue,
        :contact_email => hd[:contact_email].to_s,
        :contact_name  => hd[:contact_name].to_s.strip.presence,
        :cc            => hd[:cc].to_s,
        :bcc           => hd[:bcc].to_s,
        :mailbox       => mailbox,
        :user          => User.current,
        :send_mail     => send_mail,
        :move_cc       => hd[:move_cc] == '1'
      )
    # The ticket is saved by now; the agent learns on the next page what did
    # not happen. IssuesController sets its own :notice after this hook, so
    # the message goes to :error, which it leaves alone.
    rescue RedmineExpertHelpdesk::InitMailer::Error => e
      init_failed(context, e.message)
    rescue StandardError => e
      Rails.logger.error("Helpdesk InitMailer (new issue): #{e.message}\n#{e.backtrace.first(3).join("\n")}")
      init_failed(context, I18n.t(:error_helpdesk_init_mail_failed, :message => e.message))
    end

    # Controller hook: links the journal created on issue update with the
    # customer reply sent earlier via AJAX (HelpdeskMessage). The message ID
    # is sent along by the reply form as a hidden field (deterministic,
    # no timestamp matching). Additionally: SLA tracking (first reaction,
    # solution time on close, reset on reopen).
    def controller_issues_edit_after_save(context = {})
      journal = context[:journal]
      issue   = context[:issue]
      msg_id  = context[:params] && context[:params][:hd_sent_message_id].presence
      base    = normalized_ai_draft_text(context[:params] && context[:params][:hd_ai_draft_base_text])

      if journal && msg_id
        msg = HelpdeskMessage.outgoing.find_by(:id => msg_id.to_i, :issue_id => journal.journalized_id, :journal_id => nil)
        msg&.update_column(:journal_id, journal.id)
      end

      # The inserted AI draft was saved - regardless of whether it
      # was also sent out as mail. Without this marker, the
      # KnowledgeExtractor would re-ingest the text as a solution when closing.
      if journal && journal.notes.present? &&
         context[:params] && context[:params][:hd_ai_drafted].to_s == '1' &&
         normalized_ai_draft_text(journal.notes) != base
        HelpdeskAiDraftedJournal.find_or_create_by!(:journal_id => journal.id) do |r|
          r.issue_id = journal.journalized_id
          r.user_id  = (journal.user || User.current)&.id
        end
      end

      # SLA: a public comment by an agent stops the reaction clock
      if issue && journal && journal.notes.present? && !journal.private_notes?
        RedmineExpertHelpdesk::Sla.record_first_response!(issue, journal.created_on || Time.current,
                                                          :by => journal.user || User.current)
      end

      # SLA: set the solution time on close / reset it on reopen
      # (knowledge base ingest runs via Issue#after_save so that bulk/API
      # changes are captured too – see patches/issue_patch.rb).
      RedmineExpertHelpdesk::Sla.sync_solution!(issue) if issue&.saved_change_to_status_id?
    rescue StandardError => e
      Rails.logger.warn("Helpdesk: edit_after_save hook failed: #{e.message}")
    end

    def normalized_ai_draft_text(text)
      text.to_s.gsub(/\r\n?/, "\n").rstrip
    end

    # "New Helpdesk Ticket" button in the ticket list (next to "New Ticket").
    # Inserted into the context area via JavaScript.
    def view_issues_index_bottom(context = {})
      project = context[:project]
      return '' unless project&.module_enabled?(:helpdesk)
      return '' unless User.current.allowed_to?(:send_helpdesk_reply, project)
      return '' if project.helpdesk_mailboxes.enabled.none?

      new_url   = context[:controller].send(:new_project_issue_path, project, :helpdesk_init => '1')
      btn_label = I18n.t(:button_helpdesk_new_ticket)

      %(<script>
//<![CDATA[
(function() {
  var ctx = document.querySelector('#content > div.contextual');
  if (!ctx) return;
  var a = document.createElement('a');
  a.href      = #{new_url.to_json};
  a.className = 'icon icon-email';
  a.style.marginRight = '6px';
  a.textContent = #{btn_label.to_json};
  // Redmine 6/7 renders icons as SVG sprites; the old `icon icon-*` class no longer
  // supplies an icon (button looks mangled). Prepend the SVG when available.
  if (window.hdSpriteIcon) { a.insertAdjacentHTML('afterbegin', window.hdSpriteIcon('email')); }
  ctx.insertBefore(a, ctx.firstChild);
})();
//]]>
</script>)
    end

    private

    # Redmine renders flash messages as HTML; the message may carry a project
    # name or a mail server's answer.
    def init_failed(context, message)
      flash = context[:controller]&.flash
      flash[:error] = ERB::Util.h(message) if flash
    end

    # The helpdesk fields of the new-ticket form as the agent left them: the
    # form is rendered again when the tracker changes or the ticket does not
    # validate, and would otherwise come back empty. On the button's
    # GET ?helpdesk_init=1 there is nothing to keep.
    def init_values(context)
      hd = context[:controller]&.params&.[](:helpdesk_init)
      return {} unless hd.respond_to?(:to_unsafe_h)

      # Only read back into the form (escaped), never assigned to a model.
      hd.to_unsafe_h.slice('send_mail', 'contact_email', 'cc', 'bcc', 'contact_name', 'mailbox_id', 'move_cc')
        .transform_values(&:to_s)
    end

    # The participating mailboxes the form recognises in its recipient fields.
    def handover_targets(project)
      RedmineExpertHelpdesk::Handover.targets_for(project).values.map do |mb|
        { :address => mb.mailbox_address.to_s.downcase, :project => mb.project.name,
          :project_id => mb.project_id }
      end
    end

    # Config island + script for the "blacklist this file" button on every
    # attachment row. Redmine's attachment partial has no view hook and its markup
    # moved between Redmine 5, 6 and 7, so the button is placed client-side.
    #
    # The URLs carry __ID__ placeholders rather than a route per attachment: both
    # routes constrain :attachment_id to digits, so Rails refuses to generate a path
    # for the placeholder, and the script stays static and cacheable either way.
    def attachment_blacklist_assets(issue, project)
      return '' unless User.current.allowed_to?(:manage_helpdesk, project)

      # Which rows may carry the button is decided here, not in the script: the size
      # guard would otherwise have to be re-derived from the rendered "(139 Bytes)".
      # No eligible attachment means nothing to draw and nothing to ship.
      eligible = RedmineExpertHelpdesk::AttachmentBlacklist.eligible_ids(issue)
      return '' if eligible.empty?

      root = Redmine::Utils.relative_url_root.to_s
      config = {
        :eligible    => eligible,
        :postUrl     => "#{root}/helpdesk/attachments/__ID__/blacklist",
        :previewUrl  => "#{root}/helpdesk/attachments/__ID__/blacklist/preview",
        :label       => l(:button_helpdesk_blacklist_attachment),
        :title       => l(:label_helpdesk_blacklist_attachment_title),
        :confirmOne  => l(:text_helpdesk_blacklist_confirm_one),
        :confirmMany => l(:text_helpdesk_blacklist_confirm_many),
        :error       => l(:error_helpdesk_attachment_unreadable)
      }

      content_tag(:script, config.to_json.html_safe,
                  :type => 'application/json', :id => 'helpdesk-attachment-blacklist-config') +
        javascript_include_tag('helpdesk_attachment_blacklist',
                               :plugin => 'redmine_expert_helpdesk')
    end

    # Quote, template and AI-draft buttons in the toolbar of the note field.
    def note_toolbar(context, issue, project, contact)
      manage_url = nil
      if User.current.allowed_to?(:manage_helpdesk, project)
        manage_url = context[:controller].send(:settings_project_path, project, :tab => 'expert_helpdesk')
      end

      context[:controller].send(:render_to_string, {
        :partial => 'helpdesk/note_toolbar',
        :locals  => {
          :issue      => issue,
          :project    => project,
          :templates  => HelpdeskReplyTemplate.active.available_for(project).to_a,
          :manage_url => manage_url,
          # Empty unless a customer is linked and the feature is on: a
          # customer-facing draft on a ticket with no customer is unsendable
          # text that ends up saved as a public note instead.
          :ai_draft_variants => RedmineExpertHelpdesk::AnswerDrafter.menu_variants(project, contact)
        }
      })
    end

    # Reply form ("send as mail to the customer"). Without a customer contact
    # the assignment form is shown in the sidebar instead
    # (view_issues_sidebar_queries_bottom).
    def reply_form(context, issue, project, info, contact)
      mailbox = info.helpdesk_mailbox&.enabled? ? info.helpdesk_mailbox : nil
      mailbox ||= project.helpdesk_mailboxes.enabled.first

      ctx = { :issue => issue, :contact => contact, :user => User.current }
      footer_text = mailbox ?
        RedmineExpertHelpdesk::TemplateRenderer.render(mailbox.effective_footer_template, ctx) : ''

      project_setting  = HelpdeskProjectSetting.for_project(project)
      send_by_default  = project_setting.send_reply_by_default

      # Recipients of the mail that opened the ticket. Our own addresses and the
      # customer drop out: the original To always contains the mailbox that
      # received the mail, and the customer is already prefilled in To.
      # from_address and reply_to_address differ from mailbox_address when an
      # SMTP From override is configured, so all three have to go.
      original = HelpdeskMessage.original_recipients_for(
        issue,
        :exclude => [contact.email, mailbox&.mailbox_address,
                     mailbox&.from_address, mailbox&.reply_to_address]
      )

      context[:controller].send(:render_to_string, {
        :partial => 'helpdesk/reply_in_edit',
        :locals  => {
          :issue                  => issue,
          :contact                => contact,
          :project                => project,
          :footer_text            => footer_text.to_s,
          :send_by_default        => send_by_default,
          :reply_status_id        => project_setting.reply_status_id,
          :reply_assign_to_sender => project_setting.reply_assign_to_sender,
          :original_to            => original[:to],
          :original_cc            => original[:cc],
          :box_color              => project_setting.effective_reply_box_color,
          :hazard_color           => project_setting.effective_reply_hazard_color,
          # Experimental hand-over: addresses the form offers to hand over to.
          # The project name only for viewers who may see that project.
          :handover_targets       => RedmineExpertHelpdesk::Handover.targets_for(project).values.map { |mb|
            { :address => mb.mailbox_address.to_s.downcase,
              :project => (mb.project.visible? ? mb.project.name : nil) }
          }
        }
      })
    end

    # "Awaiting agent" counter for the ticket list sidebar.
    # Links to the same filter as the query column so that counter and list
    # agree.
    def awaiting_agent_counter(context)
      return '' unless HelpdeskTicketInfo.awaiting_agent_enabled?

      controller = context[:controller]
      return '' if controller.nil?

      project = context[:project]
      return '' if project && !project.module_enabled?(:helpdesk)

      scope = Issue.visible.open
                   .joins("INNER JOIN helpdesk_ticket_infos hti ON hti.issue_id = #{Issue.quoted_table_name}.id")
                   .where('hti.awaiting_agent_since IS NOT NULL')
      scope = scope.where(:project_id => project.self_and_descendants.select(:id)) if project

      count = scope.count
      return '' if count.zero?

      controller.send(:render_to_string, {
        :partial => 'helpdesk/awaiting_counter',
        :locals  => { :count => count, :project => project }
      })
    rescue StandardError => e
      Rails.logger.warn("Helpdesk: awaiting_agent_counter failed: #{e.message}")
      ''
    end
  end
end

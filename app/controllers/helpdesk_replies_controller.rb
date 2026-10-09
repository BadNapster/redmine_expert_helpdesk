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

    reply_to  = params[:reply_to].to_s.strip.presence  || contact.email
    reply_cc  = params[:reply_cc].to_s.strip.gsub(/[\s,;]+\z/, '')
    reply_bcc = params[:reply_bcc].to_s.strip.gsub(/[\s,;]+\z/, '')

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

    # Pending attachments (inserted images, not yet saved) by token
    inline_tokens = Array(params[:inline_attachment_tokens]).map(&:to_s).reject(&:blank?).first(20)
    inline_atts   = inline_tokens.filter_map { |tok| Attachment.find_by_token(tok) }
                                 .select { |a| a.author_id == User.current.id }

    message_id = nil

    # Inline image candidates: freshly inserted uploads AND the ticket's own
    # image attachments — a quote of the original mail refers to the latter.
    image_atts = RedmineExpertHelpdesk::ReplyImages.candidates(@issue, inline_atts)

    if mailbox.outgoing_route == 'smtp'
      processed_html, embedded_atts = RedmineExpertHelpdesk::ReplyImages.to_data_uri(body_html, image_atts)
      message_id = send_reply_smtp(mailbox, reply_to, reply_cc, reply_bcc, subject, processed_html,
                                   valid_att_ids, embedded_atts, sent_filenames)
    else
      # Raw MIME delivery for reliable CID inline images – both via the Graph
      # API and via the mailbox's own SMTP server. The JSON approach does not
      # work because Exchange rewrites the HTML before delivery and in doing so
      # separates cid: references from isInline attachments. With
      # Content-Type: text/plain + base64 MIME the MIME structure is preserved.
      message_id             = generate_message_id(mailbox.mailbox_address)
      regular_atts           = Attachment.where(:id => valid_att_ids).to_a
      cid_map, html_with_cid = RedmineExpertHelpdesk::ReplyImages.to_cid(body_html, image_atts)
      mime_msg = build_cid_mime(mailbox.mailbox_address, reply_to, reply_cc, reply_bcc,
                                subject, html_with_cid, cid_map, regular_atts, message_id)
      RedmineExpertHelpdesk::MailLogger.track(
        :kind => 'reply', :mailbox => mailbox, :issue => @issue,
        :to => reply_to, :cc => reply_cc, :bcc => reply_bcc,
        :subject => subject, :message_id => message_id
      ) do
        RedmineExpertHelpdesk::MailProvider.outgoing_for(mailbox).send_mail_mime(mime_msg)
      end
      sent_filenames.concat(regular_atts.map(&:filename))
      sent_filenames.concat(cid_map.keys.map(&:filename))
    end

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

    render :json => { :success => true, :helpdesk_message_id => hd_msg.id }
  rescue RedmineExpertHelpdesk::MailProvider::ProviderError => e
    render :json => { :success => false, :error => e.message }, :status => :unprocessable_entity
  rescue StandardError => e
    render :json => { :success => false, :error => e.message }, :status => :unprocessable_entity
  end

  private

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

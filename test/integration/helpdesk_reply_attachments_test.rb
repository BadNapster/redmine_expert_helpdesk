require File.expand_path('../../test_helper', __FILE__)

# Files the agent attaches through Redmine's standard attachment field while
# answering are *pending* uploads: saved with a token, but not attached to the
# ticket yet - the issue form only saves them on submit, and the mail goes out
# before that. They must still reach the customer: the reply form collects all
# pending attachment tokens, and the reply controller attaches every pending
# upload to the outgoing mail next to the ticket attachments the agent checked
# in the reply block's own list.
class HelpdeskReplyAttachmentsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :journals

  PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='.freeze

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :send_helpdesk_reply, :view_helpdesk_info)

    # 'smtp' goes through Redmine's global ActionMailer relay. Force the test
    # delivery method so the assembled message lands in
    # ActionMailer::Base.deliveries instead of a real SMTP connection - this
    # image ships an smtp_settings configuration that would otherwise make the
    # test talk to the actual relay.
    @mailbox = HelpdeskMailbox.create!(:project => @project,
                                       :mailbox_address => 'support@example.com',
                                       :reply_transport => 'smtp',
                                       :enabled => true)

    @previous_delivery_method = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :test

    HelpdeskContact.where(:project_id => @project.id).delete_all
    @contact = HelpdeskContact.create!(:project_id => @project.id,
                                       :email => 'kunde@example.com', :name => 'Kunde')
    @issue = Issue.find(1)
    HelpdeskTicketInfo.create!(:issue_id => @issue.id, :helpdesk_contact_id => @contact.id)

    ActionMailer::Base.deliveries.clear
    log_user('jsmith', 'jsmith') # Manager in project 1
  end

  def teardown
    ActionMailer::Base.delivery_method = @previous_delivery_method
    ActionMailer::Base.deliveries.clear
  end

  # A standard-form upload: an Attachment row with a token but no container.
  def pending_upload(filename, content_type, body)
    io = StringIO.new(body)
    io.define_singleton_method(:original_filename) { filename }
    io.define_singleton_method(:content_type) { content_type }
    Attachment.create!(:author => User.find(2), :file => io)
  end

  def upload(filename, content_type, body)
    io = StringIO.new(body)
    io.define_singleton_method(:original_filename) { filename }
    io.define_singleton_method(:content_type) { content_type }
    io
  end

  def send_reply(params = {})
    post "/issues/#{@issue.id}/helpdesk_reply",
         :params => { :note_content => 'Ответ с вложением.',
                      :reply_to     => @contact.email }.merge(params)
    assert_response :success
    ActiveSupport::JSON.decode(response.body)['success']
  end

  # The reported bug: a PDF added through the standard attachment field never
  # reached the customer. Its token must now resolve into a file attachment of
  # the outgoing mail.
  def test_a_standard_form_attachment_is_sent_with_the_reply
    pdf = pending_upload('handbuch.pdf', 'application/pdf', '%PDF-1.4')

    assert send_reply(:inline_attachment_tokens => [pdf.token])

    mail = ActionMailer::Base.deliveries.last
    assert mail, 'no mail was delivered'
    assert_equal [@contact.email], mail.to
    part = mail.attachments.detect { |a| a.filename == 'handbuch.pdf' }
    assert part, 'the pending upload is missing from the outgoing mail'
    assert_equal '%PDF-1.4', part.body.decoded
  end

  # Several standard-form files ride along together, deduplicated.
  def test_all_pending_uploads_are_attached
    pdf = pending_upload('handbuch.pdf', 'application/pdf', '%PDF-1.4')
    txt = pending_upload('notes.txt', 'text/plain', 'Inhalt')

    assert send_reply(:inline_attachment_tokens => [pdf.token, txt.token])

    mail = ActionMailer::Base.deliveries.last
    filenames = mail.attachments.map(&:filename)
    assert_includes filenames, 'handbuch.pdf'
    assert_includes filenames, 'notes.txt'
  end

  # A pending image that is not referenced by the note text is still a file the
  # agent attached - it goes out as a regular attachment, not silently dropped.
  def test_a_pending_image_not_referenced_in_the_body_is_still_sent
    png = pending_upload('diagram.png', 'image/png', Base64.decode64(PNG_BASE64))

    assert send_reply(:inline_attachment_tokens => [png.token],
                      :note_content => 'Без ссылки на картинку.')

    mail = ActionMailer::Base.deliveries.last
    assert_includes mail.attachments.map(&:filename), 'diagram.png'
  end

  # An image the note text references is embedded inline (data URI) and must
  # not be attached as a file a second time on top of that. The note carries
  # the reference as raw HTML - Redmine's textile formatter passes <img> tags
  # through unchanged, while `!filename!` markup only resolves for images that
  # are already attached to the ticket (a pending upload is not).
  def test_a_referenced_pending_image_is_embedded_and_not_duplicated
    png = pending_upload('image001.png', 'image/png', Base64.decode64(PNG_BASE64))

    assert send_reply(:inline_attachment_tokens => [png.token],
                      :note_content => 'Смотри: <img src="image001.png">')

    mail = ActionMailer::Base.deliveries.last
    html = mail.html_part ? mail.html_part.body.decoded : mail.body.decoded
    assert_match(/src="data:image\/png;base64,/, html)
    assert_equal 1, mail.attachments.size,
                 'the inline-referenced image must not be attached as a file twice'
  end

  # A token that belongs to someone else is not the agent's to send.
  def test_another_users_pending_upload_is_not_sent
    other = Attachment.create!(:author => User.find(1), :file => upload('secret.pdf', 'application/pdf', 'x'))

    assert send_reply(:inline_attachment_tokens => [other.token])

    mail = ActionMailer::Base.deliveries.last
    refute_includes mail.attachments.map(&:filename), 'secret.pdf'
  end

  # The checked ticket attachments keep working side by side with the pending
  # uploads - both end up in the same mail.
  def test_checked_ticket_attachments_and_pending_uploads_both_go_out
    old = Attachment.create!(:container => @issue, :author => User.find(2),
                             :file => upload('alt.txt', 'text/plain', 'stored'))
    pdf = pending_upload('neu.pdf', 'application/pdf', '%PDF-1.4')

    assert send_reply(:attachment_ids => [old.id],
                      :inline_attachment_tokens => [pdf.token])

    filenames = ActionMailer::Base.deliveries.last.attachments.map(&:filename)
    assert_includes filenames, 'alt.txt'
    assert_includes filenames, 'neu.pdf'
  end
end

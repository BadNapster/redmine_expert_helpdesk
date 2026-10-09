require File.expand_path('../../test_helper', __FILE__)

# The reply form prefills To with the customer and Cc with the addresses the
# mail that opened the ticket was copied to. Those original recipients are
# stored with every incoming mail: the original Cc rides along on the answer
# automatically, while the original To (everyone besides our own mailbox and
# the customer) is offered behind the To field rather than prefilled - having
# to reopen the original mail and retype them by hand is what made them get
# dropped from the answer.
class HelpdeskReplyOriginalRecipientsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :send_helpdesk_reply, :view_helpdesk_info)

    # The reply block is only rendered for a ticket that has a customer contact.
    HelpdeskContact.where(:project_id => @project.id).delete_all
    @contact = HelpdeskContact.create!(:project_id => @project.id,
                                       :email => 'kunde@example.com', :name => 'Kunde')
    @issue = Issue.find(1)
    HelpdeskTicketInfo.create!(:issue_id => @issue.id, :helpdesk_contact_id => @contact.id)

    log_user('jsmith', 'jsmith') # Manager in project 1
  end

  def inbound(to, cc = nil)
    HelpdeskMessage.create!(:issue => @issue, :direction => 'in',
                            :recipient_to => to, :recipient_cc => cc)
  end

  # To offers the original To and Cc the original Cc: the customer's own
  # addressing is the best guess at who belongs where.
  def test_buttons_carry_the_original_recipients_per_field
    inbound('kunde@example.com, chef@kunde.de', 'kollege@kunde.de')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'span.hd-orig-wrap[data-hd-field="hd-to"][data-hd-original=?]',
                  ['chef@kunde.de'].to_json
    assert_select 'span.hd-orig-wrap[data-hd-field="hd-cc"][data-hd-original=?]',
                  ['kollege@kunde.de'].to_json
  end

  # The Cc of the mail that opened the ticket is the audience of that ticket,
  # so it is prefilled - no extra click to keep the copied people in the loop.
  def test_cc_is_prefilled_with_the_original_cc_recipients
    inbound('kunde@example.com, chef@kunde.de', 'kollege@kunde.de')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'input#hd-cc[value=?]', 'kollege@kunde.de'
  end

  # Multiple Cc addresses are prefilled as a comma-separated list, the same
  # separator the agent's own input and the checklist writes.
  def test_cc_is_prefilled_with_all_the_original_cc_recipients
    inbound('kunde@example.com', 'kollege@kunde.de, leiter@kunde.de')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'input#hd-cc[value=?]', 'kollege@kunde.de, leiter@kunde.de'
  end

  # Nothing to copy, nothing prefilled: a ticket that arrived without a Cc must
  # not gain an empty-looking Cc field.
  def test_cc_stays_empty_without_original_cc_recipients
    inbound('kunde@example.com, chef@kunde.de')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'input#hd-cc[value=?]', ''
  end

  # The customer sits in the To field already, so offering them again is noise.
  # With nothing left to offer the button is absent rather than empty.
  def test_no_button_when_only_the_customer_was_addressed
    inbound('kunde@example.com')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'span.hd-orig-wrap', 0
  end

  def test_no_button_without_an_inbound_mail
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'span.hd-orig-wrap', 0
  end

  # An inbound Bcc is stripped by the sending server, so there is nothing to
  # offer there and never will be.
  def test_bcc_never_gets_a_button
    inbound('kunde@example.com, chef@kunde.de', 'kollege@kunde.de')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'span.hd-orig-wrap[data-hd-field="hd-bcc"]', 0
  end
end

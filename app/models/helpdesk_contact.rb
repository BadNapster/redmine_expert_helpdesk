# Customer/contact: created automatically from the mail sender and linked to
# tickets (customer info panel on the ticket page). Contacts are project-specific:
# each project maintains its own customer list with its own metadata (company,
# phone, notes etc.).
class HelpdeskContact < HelpdeskApplicationRecord
  include Redmine::SafeAttributes

  belongs_to :project, :optional => true
  has_many :helpdesk_messages, :dependent => :nullify
  # Nullify like the messages: without it a destroyed contact leaves a
  # dangling helpdesk_contact_id behind (the customer columns/filter guard
  # against legacy dangling rows, but new ones should not be created).
  has_many :helpdesk_ticket_infos, :dependent => :nullify

  validates :email, :presence => true
  validates :email, :uniqueness => { :scope => :project_id, :case_sensitive => false }

  # info_request_opt_out marks a sender nobody could answer a follow-up for (Veeam
  # job report, cron mail, monitoring alert). HelpdeskCompletenessJob reads it in
  # both modes, next to the project-wide info_request_sender_blacklist.
  safe_attributes 'name', 'company', 'phone', 'notes', 'info_request_opt_out'

  # Finds or creates a contact for the given e-mail address
  # in the context of the given project.
  def self.find_or_create_for(email, name = nil, project = nil)
    email = email.to_s.downcase.strip
    scope = project ? where(:project_id => project.id) : where(:project_id => nil)
    contact = scope.where('LOWER(email) = ?', email).first
    contact ||= create!(:email => email, :name => name.presence, :project => project)
    # Backfill the name if it was unknown so far
    contact.update_column(:name, name) if contact.name.blank? && name.present?
    contact
  end

  def display_name
    name.presence || email
  end

  # Tickets to which messages of this contact exist
  def issues
    Issue.where(:id => helpdesk_messages.select(:issue_id)).distinct
  end
end

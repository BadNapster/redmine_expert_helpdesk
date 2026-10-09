# A solution proposal for a ticket, derived from a similar solved ticket (RAG).
# Created during the summary and shown in the sidebar. source_issue = the
# similar, already solved ticket.
class HelpdeskKbProposal < HelpdeskApplicationRecord
  belongs_to :issue,        :optional => true
  belongs_to :source_issue, :class_name => 'Issue', :optional => true

  validates :issue_id, :presence => true
end

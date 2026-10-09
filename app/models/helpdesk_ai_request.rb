# One log entry per AI call (see migration 033). Written by the AiClient on
# summarize/embed – on success with tokens/duration, on error with
# error_class/http_status. Backing table of the project-scoped AI statistics
# (RedmineExpertHelpdesk::AiUsageStatistics).
class HelpdeskAiRequest < HelpdeskApplicationRecord
  # created_at only (no updated_at) – the log entry is immutable.
  self.record_timestamps = false

  REQUEST_TYPES = %w[summary completeness kb_extract kb_embed kb_retrieve kb_rerank answer_draft].freeze

  belongs_to :project, :optional => true
  belongs_to :issue,   :optional => true
  # Nil for the background jobs (no acting user); set for the answer draft, which
  # an agent triggers by hand and whose output is proposed to a customer.
  belongs_to :user,    :optional => true

  validates :request_type, :presence => true

  scope :successful, -> { where(:success => true) }
  scope :failed,     -> { where(:success => false) }
  scope :in_range,   ->(from, to) { where(:created_at => from...to) }

  before_create { self.created_at ||= Time.now }

  def total_tokens
    input_tokens.to_i + output_tokens.to_i
  end
end

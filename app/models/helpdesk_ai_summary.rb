# Log entry of an AI summary (provider/model + token usage), linked to the
# generated private journal note. Deliberately NOT an activity provider (unlike
# HelpdeskMessage) – the summary must not pollute the activity feed; the entry
# only serves the token display in the journal header.
class HelpdeskAiSummary < HelpdeskApplicationRecord
  belongs_to :issue
  belongs_to :journal, :optional => true

  validates :issue, :presence => true

  def total_tokens
    (input_tokens.to_i + output_tokens.to_i) if input_tokens || output_tokens
  end
end

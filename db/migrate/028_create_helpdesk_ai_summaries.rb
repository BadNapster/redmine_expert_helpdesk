# Log entry per generated AI summary: links the private journal note
# with the provider/model used and the token usage. Used to show the
# token count in the journal header (analogous to the recipient badges).
class CreateHelpdeskAiSummaries < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_ai_summaries)

    create_table :helpdesk_ai_summaries do |t|
      t.integer :issue_id,      :null => false
      t.integer :journal_id
      t.string  :provider
      t.string  :model
      t.integer :input_tokens
      t.integer :output_tokens
      t.timestamps
    end
    add_index :helpdesk_ai_summaries, :issue_id
    add_index :helpdesk_ai_summaries, :journal_id
  end
end

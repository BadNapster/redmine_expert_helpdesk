# Knowledge base entry per solved ticket: the extracted {problem, solution}
# as the system of record (dedup, curation, re-embed source). The vectors
# themselves live in the external vector store (Qdrant/pgvector); here only metadata
# + status (pending/approved/skipped) + reference to the vector point.
class CreateHelpdeskKnowledgeEntries < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_knowledge_entries)

    create_table :helpdesk_knowledge_entries do |t|
      t.integer :project_id, :null => false
      t.integer :issue_id,   :null => false
      t.text    :problem
      t.text    :solution
      t.string  :status, :limit => 10, :default => 'pending', :null => false
      t.string  :embed_model
      t.string  :point_id
      t.integer :input_tokens
      t.integer :output_tokens
      t.timestamps
    end
    add_index :helpdesk_knowledge_entries, :project_id
    add_index :helpdesk_knowledge_entries, :issue_id, :unique => true
  end
end

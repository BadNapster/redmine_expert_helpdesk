# Uniform usage log for EVERY AI call (summary,
# knowledge-base extraction, embedding, RAG retrieval). Basis of the AI statistics:
# records provider/model, tokens, duration and success/failure per request – incl.
# failed attempts (otherwise only logged) and with direct project assignment.
class CreateHelpdeskAiRequests < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_ai_requests)

    create_table :helpdesk_ai_requests do |t|
      t.string   :request_type, :null => false   # summary | kb_extract | kb_embed | kb_retrieve
      t.string   :provider
      t.string   :model
      t.integer  :project_id                      # from the job context, usually set
      t.integer  :issue_id
      t.integer  :input_tokens
      t.integer  :output_tokens
      t.integer  :duration_ms
      t.boolean  :success, :null => false, :default => true
      t.string   :error_class                     # nil on success
      t.integer  :http_status                     # from AiError#status on error
      t.datetime :created_at, :null => false
    end
    add_index :helpdesk_ai_requests, [:project_id, :created_at]
    add_index :helpdesk_ai_requests, [:request_type, :created_at]
    add_index :helpdesk_ai_requests, :issue_id
  end
end

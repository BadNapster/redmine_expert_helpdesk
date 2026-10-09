# Per-project control of the knowledge base (RAG):
#  - kb_ingest_mode:      off | auto | manual  (does this project contribute solved
#                         tickets to the knowledge base, and how?)
#  - kb_proposal_display: off | summary | sidebar | both  (does this project
#                         use the knowledge base for solution proposals, and where?)
class AddKbSettingsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      t.string :kb_ingest_mode,      :limit => 10, :default => 'off', :null => false unless column_exists?(:helpdesk_project_settings, :kb_ingest_mode)
      t.string :kb_proposal_display, :limit => 10, :default => 'off', :null => false unless column_exists?(:helpdesk_project_settings, :kb_proposal_display)
    end
  end
end

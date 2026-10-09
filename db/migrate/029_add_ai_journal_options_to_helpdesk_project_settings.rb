# Further per-project options for the AI summary:
#  - ai_include_journal:        give the AI the full ticket history (description + notes)
#                               instead of only the triggering mail
#  - ai_include_private_notes:  also include private notes (only effective
#                               when ai_include_journal is active)
class AddAiJournalOptionsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      t.boolean :ai_include_journal,       :default => false, :null => false unless column_exists?(:helpdesk_project_settings, :ai_include_journal)
      t.boolean :ai_include_private_notes, :default => false, :null => false unless column_exists?(:helpdesk_project_settings, :ai_include_private_notes)
    end
  end
end

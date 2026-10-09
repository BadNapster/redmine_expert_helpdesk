# Direct link of incoming messages to their journal.
# Replaces the timestamp matching in the frontend for incoming mails
# (MailHandler delivers the journal object directly, the ID can be stored).
class AddJournalIdToHelpdeskMessages < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_messages, :journal_id)
      add_column :helpdesk_messages, :journal_id, :integer
      add_index :helpdesk_messages, :journal_id
    end
  end
end

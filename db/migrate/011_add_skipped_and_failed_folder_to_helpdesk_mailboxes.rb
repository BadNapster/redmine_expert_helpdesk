class AddSkippedAndFailedFolderToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    # Target folder for skipped mails (blacklist, ignore rules, auto-reply filter)
    add_column :helpdesk_mailboxes, :skipped_folder, :string unless column_exists?(:helpdesk_mailboxes, :skipped_folder)
    # Target folder for mails whose processing failed
    add_column :helpdesk_mailboxes, :failed_folder, :string unless column_exists?(:helpdesk_mailboxes, :failed_folder)
  end
end

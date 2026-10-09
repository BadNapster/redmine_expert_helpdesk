# Controls how the mailbox footer is combined with the central signature:
#   inherit  - use the central signature (default)
#   prepend  - insert the mailbox footer BEFORE the central signature
#   override - use only the mailbox footer
class AddFooterModeToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_mailboxes, :footer_mode)
      add_column :helpdesk_mailboxes, :footer_mode, :string, :limit => 20, :default => 'inherit', :null => false
    end
  end
end

class AddReopenSettingsToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    # Status a closed ticket is set to when a new reply arrives
    add_column :helpdesk_mailboxes, :reopen_status_id, :integer unless column_exists?(:helpdesk_mailboxes, :reopen_status_id)
    # Maximum age (days since last update) for reopening.
    # If the ticket is older, a new ticket is created instead.
    # Empty / 0 = no age limit (always reopen, as long as a status is configured).
    add_column :helpdesk_mailboxes, :reopen_max_age_days, :integer unless column_exists?(:helpdesk_mailboxes, :reopen_max_age_days)
  end
end

class AddAutoReplyFilterToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    # Filtering of automatically generated messages (auto-reply, out-of-office, etc.)
    add_column :helpdesk_mailboxes, :auto_reply_filter_enabled,   :boolean, :default => false, :null => false unless column_exists?(:helpdesk_mailboxes, :auto_reply_filter_enabled)
    # Sender whitelist: addresses/domains whose auto-replies are still processed
    add_column :helpdesk_mailboxes, :auto_reply_sender_whitelist, :text unless column_exists?(:helpdesk_mailboxes, :auto_reply_sender_whitelist)
    # Header whitelist: "Header: value" entries that disable the auto-reply filter
    add_column :helpdesk_mailboxes, :auto_reply_header_whitelist, :text unless column_exists?(:helpdesk_mailboxes, :auto_reply_header_whitelist)
  end
end

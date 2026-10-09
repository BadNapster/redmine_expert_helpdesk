# PhishTank URLs contain 4-byte UTF-8 characters (homoglyph domains such as
# mathematical letters, a common phishing trick). Redmine's
# standard charset utf8mb3 cannot store these (Mysql2::Error:
# Incorrect string value) – convert the table to utf8mb4.
class ConvertHelpdeskPhishingUrlsToUtf8mb4 < ActiveRecord::Migration[6.1]
  def up
    return unless ActiveRecord::Base.connection.adapter_name =~ /mysql/i

    execute 'ALTER TABLE helpdesk_phishing_urls CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'
  end

  def down
    # No reverse conversion: utf8mb4 is downwards compatible with utf8mb3
  end
end

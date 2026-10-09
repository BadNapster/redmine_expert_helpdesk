# Local mirror of the PhishTank database (known phishing URLs).
# Updated periodically via PhishtankSync (full import).
class CreateHelpdeskPhishingUrls < ActiveRecord::Migration[6.1]
  def change
    create_table :helpdesk_phishing_urls do |t|
      t.text     :url,         :null => false                 # Original URL from the PhishTank feed
      t.string   :url_hash,    :null => false, :limit => 64   # SHA-256 of the normalized URL (lookup key)
      t.integer  :phish_id                                    # PhishTank ID (for reference/detail link)
      t.string   :target                                      # Attacked brand (e.g. "PayPal")
      t.datetime :imported_at, :null => false                 # Time of import (for stale? check)
    end

    add_index :helpdesk_phishing_urls, :url_hash, :unique => true
    add_index :helpdesk_phishing_urls, :phish_id
  end
end

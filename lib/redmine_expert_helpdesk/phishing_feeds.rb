# Orchestrates the phishing feed synchronization (PhishTank + Phishing.Database):
# - run_if_stale: automatic sync on mail fetch (fetch_all), per source
#   only when the interval has elapsed; Rails.cache lock against double runs
# - run_all: manual sync (button in the plugin settings, rake task)
module RedmineExpertHelpdesk
  class PhishingFeeds
    LOCK_KEY = 'redmine_expert_helpdesk/phishing_feeds_sync_lock'.freeze

    # Returns the enabled feeds as [[source, sync_object], ...].
    # PhishTank is always included (the master switch phishtank_enabled is
    # a prerequisite for the whole phishing feature).
    def self.enabled_feeds(settings)
      feeds = [
        [PhishtankSync::SOURCE, PhishtankSync.new(settings['phishtank_app_key'], settings['phishtank_feed_url'])]
      ]
      if settings['phishing_database_enabled'] == '1'
        feeds << [PhishingDatabaseSync::SOURCE, PhishingDatabaseSync.new(settings['phishing_database_feed_url'])]
      end
      feeds
    end

    # Manual sync of all enabled feeds.
    # Returns [results, errors]: { source => count } / { source => error message }.
    def self.run_all
      settings = Setting.plugin_redmine_expert_helpdesk
      results = {}
      errors  = {}
      return [results, errors] unless settings['phishtank_enabled'] == '1'

      enabled_feeds(settings).each do |source, sync|
        begin
          results[source] = sync.run
        rescue StandardError => e
          errors[source] = e.message
        end
      end

      [results, errors]
    end

    # Automatic sync: only due sources, with a lock against parallel downloads.
    # Returns true when at least one sync ran.
    def self.run_if_stale
      settings = Setting.plugin_redmine_expert_helpdesk
      return false unless settings['phishtank_enabled'] == '1'

      interval = [settings['phishtank_interval_hours'].to_i, 1].max
      due = enabled_feeds(settings).select do |source, _sync|
        HelpdeskPhishingUrl.stale?(interval, source)
      end
      return false if due.empty?

      return false unless Rails.cache.write(LOCK_KEY, Time.current.to_i, :unless_exist => true, :expires_in => 30.minutes)

      begin
        due.each do |source, sync|
          begin
            sync.run
          rescue StandardError => e
            Rails.logger.error "Helpdesk: Feed sync '#{source}' failed: #{e.message}"
          end
        end
        true
      ensure
        Rails.cache.delete(LOCK_KEY)
      end
    end
  end
end

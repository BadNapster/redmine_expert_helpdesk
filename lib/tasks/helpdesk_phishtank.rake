# Manual or cron trigger for the phishing feed sync (PhishTank + Phishing.Database):
#   bundle exec rake redmine_expert_helpdesk:phishtank_sync RAILS_ENV=production
namespace :redmine_expert_helpdesk do
  desc 'Downloads the enabled phishing feeds and refreshes the local mirror'
  task :phishtank_sync => :environment do
    settings = Setting.plugin_redmine_expert_helpdesk
    unless settings['phishtank_enabled'] == '1'
      puts 'Phishing integration is disabled in the plugin settings.'
      next
    end

    results, errors = RedmineExpertHelpdesk::PhishingFeeds.run_all
    results.each { |source, count| puts "#{source}: #{count} URLs imported." }
    errors.each  { |source, msg|   puts "#{source}: ERROR - #{msg}" }
  end
end

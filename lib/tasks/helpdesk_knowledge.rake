# Knowledge base batch tasks.
#
#   bundle exec rake redmine_expert_helpdesk:kb_backfill RAILS_ENV=production
#   bundle exec rake redmine_expert_helpdesk:kb_reembed  RAILS_ENV=production
#   bundle exec rake redmine_expert_helpdesk:kb_reextract [PROJECT=<id|identifier>] [ALL=1] RAILS_ENV=production
#
namespace :redmine_expert_helpdesk do
  desc 'Adds already closed tickets of contributing projects to the knowledge base'
  task :kb_backfill => :environment do
    unless RedmineExpertHelpdesk::AiFeatures.kb_enabled?
      puts 'The knowledge base is disabled in the plugin settings.'
      next
    end

    total = 0
    HelpdeskProjectSetting.where.not(:kb_ingest_mode => 'off').find_each do |ps|
      project = Project.find_by(:id => ps.project_id)
      next unless project

      scope = Issue.where(:project_id => project.id)
                   .joins(:status).where(:issue_statuses => { :is_closed => true })
                   .where.not(:id => HelpdeskKnowledgeEntry.where(:project_id => project.id).select(:issue_id))
      count = 0
      scope.find_each do |issue|
        HelpdeskKnowledgeIngestJob.perform_later(issue.id)
        count += 1
      end
      total += count
      puts "#{project.identifier}: #{count} tickets queued for ingestion."
    end
    puts "Total queued: #{total}."
  end

  desc 'Rebuilds the vectors of all approved knowledge base entries (e.g. after a model change)'
  task :kb_reembed => :environment do
    settings = Setting.plugin_redmine_expert_helpdesk
    unless RedmineExpertHelpdesk::AiFeatures.kb_enabled?
      puts 'The knowledge base is disabled.'
      next
    end

    store = RedmineExpertHelpdesk::KnowledgeStore.for(settings)
    unless store.configured?
      puts 'The vector store is not configured.'
      next
    end

    # Same per-project rebuild as the "Knowledge base" tab (reset + re-embed). With
    # Qdrant the collection is recreated with the current dimension; with pgvector a
    # changed dimension needs the helpdesk_kb_vectors table dropped by hand.
    # Projects with entries plus every helpdesk project: a project whose last entry
    # was deleted may still hold orphan points, and only a reset clears them.
    pids = HelpdeskKnowledgeEntry.distinct.pluck(:project_id) |
           EnabledModule.where(:name => 'helpdesk').pluck(:project_id)
    ok = 0
    pids.sort.each do |pid|
      count = HelpdeskKnowledgeReindexJob.rebuild(pid)
      if count.nil?
        puts "Project #{pid}: rebuild failed (see log)."
      else
        ok += count
      end
    end
    puts "Reindexed: #{ok} entries."
  end

  desc 'Re-extracts knowledge base entries with the current detail level (PROJECT=<id|identifier>, ALL=1 = all)'
  task :kb_reextract => :environment do
    unless RedmineExpertHelpdesk::AiFeatures.kb_ready?
      puts 'The knowledge base is disabled or not fully configured.'
      next
    end

    all = ENV['ALL'] == '1'
    projects =
      if ENV['PROJECT'].present?
        [Project.find_by(:id => ENV['PROJECT']) || Project.find_by(:identifier => ENV['PROJECT'])].compact
      else
        Project.where(:id => HelpdeskProjectSetting.where.not(:kb_ingest_mode => 'off').select(:project_id)).to_a
      end
    if projects.empty?
      puts 'No matching project found.'
      next
    end

    total = 0
    projects.each do |project|
      level = HelpdeskProjectSetting.for_project(project).effective_kb_extract_detail
      count = HelpdeskKnowledgeReextractJob.enqueue(project.id, :all => all).to_i
      total += count
      puts "#{project.identifier} (#{level}): #{count} entries queued for re-extraction."
    end
    puts "Total queued: #{total} (one AI call per entry)."
  end
end

# SLA statistics of a project ("SLA statistics" tab).
# Only reachable when SLA is active for the project.
class HelpdeskSlaStatisticsController < ApplicationController
  include HelpdeskStatsDateRange

  before_action :find_project_by_project_id
  before_action :authorize
  before_action :require_sla_enabled

  def index
    @period = RedmineExpertHelpdesk::SlaStatistics::PERIODS.include?(params[:period]) ?
                params[:period] : 'month'
    @range = resolve_range
    @date_to, @date_from = range_dates(@range)

    @stats = RedmineExpertHelpdesk::SlaStatistics.new(
      @project, :period => @period, :date_from => @date_from, :date_to => @date_to).to_h
  end

  private

  def require_sla_enabled
    render_403 unless HelpdeskProjectSetting.for_project(@project).sla_enabled?
  end
end

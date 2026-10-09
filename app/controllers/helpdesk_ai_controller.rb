# Manually (re-)creating the AI summary of a ticket from the ticket sidebar.
# Triggers HelpdeskAiSummaryJob with force=true (regardless of the project-
# specific activation/scope), provided the AI is centrally enabled and
# configured.
class HelpdeskAiController < ApplicationController
  before_action :find_issue_and_project
  before_action :authorize_regenerate

  def regenerate
    settings = Setting.plugin_redmine_expert_helpdesk
    unless RedmineExpertHelpdesk::AiFeatures.ai_enabled? &&
           RedmineExpertHelpdesk::AiClient.new(settings).configured?
      flash[:warning] = l(:text_helpdesk_ai_not_configured)
      return redirect_to issue_path(@issue)
    end

    # Summarize the ticket's first mail (oldest incoming message).
    message = HelpdeskMessage.where(:issue_id => @issue.id, :direction => 'in').order(:id => :asc).first
    HelpdeskAiSummaryJob.perform_later(@issue.id, :message_id => message&.id, :force => true)

    flash[:notice] = l(:notice_helpdesk_ai_regenerate_queued)
    redirect_to issue_path(@issue)
  end

  private

  def find_issue_and_project
    @issue   = Issue.find(params[:issue_id])
    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_regenerate
    deny_access unless User.current.allowed_to?(:send_helpdesk_reply, @project)
  end
end

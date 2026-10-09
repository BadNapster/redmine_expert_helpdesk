# Triggers the mail fetch:
#   - fetch:     button in the project settings (permission :fetch_helpdesk_mail)
#   - fetch_all: global endpoint for curl/CronJob, secured by a static API key
#   - maintenance: status (GET) and switch (POST) of maintenance mode, same key as fetch_all
class HelpdeskFetchController < ApplicationController
  before_action :find_project_by_project_id, :only => [:fetch]
  before_action :authorize, :only => [:fetch]

  skip_before_action :check_if_login_required, :only => [:fetch_all, :sla_check, :maintenance]
  skip_before_action :verify_authenticity_token, :only => [:fetch_all, :sla_check, :maintenance]

  def fetch
    if RedmineExpertHelpdesk::Maintenance.active?
      respond_to do |format|
        format.html do
          flash[:warning] = l(:notice_helpdesk_maintenance_fetch_blocked)
          redirect_to settings_project_path(@project, :tab => 'expert_helpdesk')
        end
        format.json { render :json => { :maintenance => true }, :status => 503 }
      end
      return
    end

    results = @project.helpdesk_mailboxes.enabled.map do |mailbox|
      result = RedmineExpertHelpdesk::MailProcessor.new(mailbox).process_all
      [mailbox.mailbox_address, result.to_h]
    end.to_h

    respond_to do |format|
      format.html do
        flash[:notice] = l(:notice_helpdesk_fetch_done, :count => results.values.sum { |r| r[:processed] })
        redirect_to settings_project_path(@project, :tab => 'expert_helpdesk')
      end
      format.json { render :json => results }
    end
  rescue RedmineExpertHelpdesk::MailProvider::ProviderError => e
    respond_to do |format|
      format.html do
        flash[:error] = l(:error_helpdesk_fetch_failed, :message => e.message)
        redirect_to settings_project_path(@project, :tab => 'expert_helpdesk')
      end
      format.json { render :json => { :error => e.message }, :status => 502 }
    end
  end

  def fetch_all
    unless valid_api_key?('fetch_api_key')
      render :json => { :error => l(:error_helpdesk_invalid_api_key) }, :status => 401
      return
    end

    # 200, not 503: the cron job did nothing wrong, and a failing curl -f
    # would page someone for a pause that was switched on deliberately.
    if RedmineExpertHelpdesk::Maintenance.active?
      render :json => { :fetched_at => Time.current.iso8601, :maintenance => true, :mailboxes => {} }
      return
    end

    summary = {}
    HelpdeskMailbox.enabled.includes(:project).each do |mailbox|
      next unless mailbox.project&.active? && mailbox.project.module_enabled?(:helpdesk)

      begin
        summary[mailbox.mailbox_address] = RedmineExpertHelpdesk::MailProcessor.new(mailbox).process_all.to_h
      rescue StandardError => e
        Rails.logger.error "Helpdesk: fetch for #{mailbox.mailbox_address} failed: #{e.message}"
        summary[mailbox.mailbox_address] = { :error => e.message }
      end
    end

    # Refresh the phishing feeds when needed (piggybacked on the cron fetch).
    # Errors must never affect the mail fetch.
    begin
      RedmineExpertHelpdesk::PhishingFeeds.run_if_stale
    rescue StandardError => e
      Rails.logger.error "Helpdesk: feed sync in fetch_all failed: #{e.message}"
    end

    render :json => { :fetched_at => Time.current.iso8601, :mailboxes => summary }
  end

  # GET: maintenance flag plus the fetches still in progress on any pod.
  # POST enabled=1|0: switches the flag, then answers with the same status.
  # Poll GET until safe_to_stop is true before scaling the pods down.
  def maintenance
    unless valid_api_key?('fetch_api_key')
      render :json => { :error => l(:error_helpdesk_invalid_api_key) }, :status => 401
      return
    end

    if request.post?
      unless %w[0 1].include?(params[:enabled].to_s)
        render :json => { :error => 'enabled must be 1 or 0' }, :status => 422
        return
      end
      RedmineExpertHelpdesk::Maintenance.set!(params[:enabled].to_s == '1')
    end

    render :json => RedmineExpertHelpdesk::Maintenance.status
  end

  # Global SLA check for an external cron job (e.g. via curl), secured by its
  # own API key. Runs only the SLA breach check; overlapping runs are prevented
  # by the cache lock in run_if_due.
  def sla_check
    unless valid_api_key?('sla_api_key')
      render :json => { :error => l(:error_helpdesk_invalid_api_key) }, :status => 401
      return
    end

    notified = RedmineExpertHelpdesk::SlaBreachCheck.run_if_due

    if notified == false
      # Lock held => another run is active, no overlapping check
      render :json => { :checked_at => Time.current.iso8601, :skipped => true }
    else
      render :json => { :checked_at => Time.current.iso8601, :notified => notified }
    end
  end

  private

  # Timing-safe comparison of the given ?key= against the API key setting stored
  # in the plugin settings. A blank/missing configured key => the endpoint is
  # disabled (the comparison fails).
  def valid_api_key?(setting_key)
    configured = Setting.plugin_redmine_expert_helpdesk[setting_key].to_s
    provided   = params[:key].to_s

    configured.present? && provided.present? &&
      ActiveSupport::SecurityUtils.secure_compare(configured, provided)
  end
end

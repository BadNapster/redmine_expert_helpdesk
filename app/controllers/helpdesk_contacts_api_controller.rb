# REST API for helpdesk contacts (customers). JSON/XML via .api.rsb.
# Auth: X-Redmine-API-Key (only with the REST web service enabled); authorization
# via the existing permissions (read: view_helpdesk_info, write:
# manage_helpdesk_contacts). Contacts are project-scoped.
class HelpdeskContactsApiController < ApplicationController
  before_action :find_project_by_project_id, :only => [:index, :create]
  before_action :find_contact,               :only => [:show, :update, :destroy]
  before_action :authorize_read,             :only => [:index, :show]
  before_action :authorize_write,            :only => [:create, :update, :destroy]
  accept_api_auth :index, :show, :create, :update, :destroy

  def index
    scope = HelpdeskContact.where(:project_id => @project.id)
    if params[:email].present?
      scope = scope.where('LOWER(email) = ?', params[:email].to_s.downcase.strip)
    elsif params[:search].present?
      safe = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search].to_s.downcase)}%"
      scope = scope.where('LOWER(name) LIKE ? OR LOWER(email) LIKE ? OR LOWER(company) LIKE ?', safe, safe, safe)
    end

    @offset, @limit = api_offset_and_limit
    @contact_count  = scope.count
    @contacts = scope.order(:name => :asc, :email => :asc).limit(@limit).offset(@offset)
    respond_to { |format| format.api }
  end

  def show
    respond_to { |format| format.api }
  end

  def create
    attrs = params[:helpdesk_contact] || {}
    @contact = HelpdeskContact.new(:project_id => @project.id,
                                   :email => attrs[:email].to_s.downcase.strip)
    @contact.safe_attributes = attrs
    if @contact.save
      respond_to { |format| format.api { render :action => 'show', :status => :created } }
    else
      render_validation_errors(@contact)
    end
  end

  def update
    @contact.safe_attributes = params[:helpdesk_contact] || {}
    if @contact.save
      render_api_ok
    else
      render_validation_errors(@contact)
    end
  end

  def destroy
    @contact.destroy
    render_api_ok
  end

  private

  # Contact globally by ID; the project context comes from the contact itself.
  def find_contact
    @contact = HelpdeskContact.find(params[:id])
    @project = @contact.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_read
    deny_access unless read_allowed?
  end

  def authorize_write
    deny_access unless User.current.allowed_to?(:manage_helpdesk_contacts, @project)
  end

  # Without a project (global contact) admin rights suffice for reading.
  def read_allowed?
    return User.current.admin? if @project.nil?

    User.current.allowed_to?(:view_helpdesk_info, @project) ||
      User.current.allowed_to?(:manage_helpdesk_contacts, @project)
  end
end

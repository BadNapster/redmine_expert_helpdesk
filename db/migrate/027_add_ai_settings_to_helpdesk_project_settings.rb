# Project-specific settings for AI summaries of incoming mails.
# Provider/key/model/default prompt live centrally (plugin settings); here only
# the per-project control: enabled, scope (first mail only / replies too),
# prompt mode (inherit/extend/replace) + project prompt, and the choice of
# which attachments (metadata / extracted text / images) go to the AI.
class AddAiSettingsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      t.boolean :ai_summary_enabled, :default => false, :null => false unless column_exists?(:helpdesk_project_settings, :ai_summary_enabled)
      t.string  :ai_summary_scope,   :limit => 20, :default => 'initial'  unless column_exists?(:helpdesk_project_settings, :ai_summary_scope)
      t.string  :ai_prompt_mode,     :limit => 20, :default => 'inherit'  unless column_exists?(:helpdesk_project_settings, :ai_prompt_mode)
      t.text    :ai_prompt                                                unless column_exists?(:helpdesk_project_settings, :ai_prompt)
      t.boolean :ai_attach_metadata, :default => true,  :null => false    unless column_exists?(:helpdesk_project_settings, :ai_attach_metadata)
      t.boolean :ai_attach_text,     :default => false, :null => false    unless column_exists?(:helpdesk_project_settings, :ai_attach_text)
      t.boolean :ai_attach_images,   :default => false, :null => false    unless column_exists?(:helpdesk_project_settings, :ai_attach_images)
    end
  end
end

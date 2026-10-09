# Redmine Expert Helpdesk Plugin
#
# Copyright (C) 2026 Dennis Buehring
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version. See LICENSE for the full text.
#
# Email-to-ticket plugin with Microsoft Graph integration (O365, OAuth client credentials).
# Per project, mailboxes can be configured whose mails are processed as tickets
# or ticket replies.

# Keep this plugin's credentials out of the Rails parameter log.
#
# Every secret the plugin stores is posted through an ordinary settings form and
# was written to the log in clear text: the AI and embedding keys, the Qdrant
# key, the fetch/SLA endpoint keys, and the Azure client secret.
#
# Everything the plugin cares about is listed here rather than relying on the
# host's filter list. That list differs between the supported Redmine versions -
# on 6.1 and 7.0 client_secret happens to be caught by their :secret entry, on
# 5.1 and 6.0 it is not - so inheriting it would mean the secret leaks on half
# the matrix. Entries match as substrings of the parameter name, so these four
# cover the current keys and any future ones. ":key" is deliberately absent: it
# would also hide settings that are not secrets, such as info_request_keywords.
#
# Mailbox passwords are additionally encrypted at rest by SecretBox.
Rails.application.config.filter_parameters +=
  [:api_key, :app_key, :client_secret, :password]

require File.expand_path('../lib/redmine_expert_helpdesk/secret_box', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/provider_presets', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/xoauth2', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mail_logger', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/automated_mail', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mail_provider', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mailbox_credentials', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/oauth_token_provider', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/graph_client', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/graph_provider', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/imap_client', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/smtp_sender', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/imap_provider', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mailbox_folders', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/ai_logger', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/ai_features', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/ai_client', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/image_relevance', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/completeness_check', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/info_request_mailer', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/knowledge_store', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/knowledge_extractor', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/knowledge_retrieval', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/answer_drafter', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/template_renderer', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/inline_images', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/attachment_blacklist', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/reply_images', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/reply_box', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/note_quoter', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/maintenance', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mail_processor', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/init_mailer', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/hooks', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/phishtank_sync', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/phishing_database_sync', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/phishing_feeds', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/phishing_scanner', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/legacy_contacts_import', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/business_hours', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/sla', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/sla_breach_check', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/statistics_support', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/sla_statistics', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/ticket_statistics', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/ai_usage_statistics', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/api_serializers', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/projects_helper_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/project_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/issue_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/issue_query_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/queries_helper_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/issue_css_classes_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/journal_patch', __FILE__)

Redmine::Plugin.register :redmine_expert_helpdesk do
  name 'Redmine expert Helpdesk'
  author 'Dennis Buehring'
  description 'Helpdesk plugin: email-to-ticket via Microsoft Graph or IMAP/SMTP, autoresponder, customer replies, SLA, and rules engine'
  version '0.20.4'
  requires_redmine :version_or_higher => '5.0'
  url 'https://github.com/expertZentrale/redmine_expert_helpdesk'

  # Central app registration (Azure AD / Entra ID) and API key for the fetch endpoint
  settings :partial => 'settings/helpdesk_settings',
           :default => {
             'tenant_id'                => '',
             'client_id'                => '',
             'client_secret'            => '',
             'fetch_api_key'            => '',
             'sla_api_key'              => '',
             # Maintenance mode: '1' stops every mail fetch (see Maintenance).
             'maintenance_mode'         => '0',
             # Defaults for mailboxes with credentials_source = 'global'. The
             # application registration itself is tenant_id/client_id/client_secret
             # above - it is shared with the Graph provider, never duplicated here.
             'default_oauth_preset'        => 'microsoft',
             'default_oauth_grant'         => 'client_credentials',
             'default_oauth_authorize_url' => '',
             'default_oauth_token_url'     => '',
             'default_oauth_scope'         => '',
             'default_imap_host'     => '',
             'default_imap_port'     => '993',
             'default_imap_security' => 'ssl',
             'default_smtp_host'     => '',
             'default_smtp_port'     => '587',
             'default_smtp_security' => 'starttls',
             'awaiting_agent_enabled'   => '1',
             'inline_images_enabled'    => '1',
             # Colours of the customer-facing block in the edit form. The constants
             # behind them are the real fallback — see ReplyBox::DEFAULT_BOX_COLOR.
             'reply_box_color'          => RedmineExpertHelpdesk::ReplyBox::DEFAULT_BOX_COLOR,
             'reply_hazard_color'       => RedmineExpertHelpdesk::ReplyBox::DEFAULT_HAZARD_COLOR,
             # Guards on the attachment "block" button, overridable per project.
             # The constants behind them are the real fallback — see
             # AttachmentBlacklist::DEFAULT_TYPES.
             'blacklist_types'          => RedmineExpertHelpdesk::AttachmentBlacklist::DEFAULT_TYPES,
             'blacklist_max_kb'         => RedmineExpertHelpdesk::AttachmentBlacklist::DEFAULT_MAX_KB.to_s,
             'contacts_per_page'        => '25',
             'contact_ticket_limit'     => '10',
             'phishtank_enabled'        => '0',
             'phishtank_app_key'        => '',
             'phishtank_feed_url'       => 'https://data.phishtank.com/data/{key}/online-valid.json.gz',
             'phishtank_interval_hours' => '6',
             'phishing_database_enabled'  => '0',
             'phishing_database_feed_url' => 'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-links-ACTIVE.txt',
             'global_footer'            => '',
             # Issue custom fields an admin opted into as {{issue.cf.*}} macros,
             # as a comma-separated id list. Empty = no custom field macros.
             'macro_custom_field_ids'   => '',
             'ai_enabled'           => '0',
             'ai_provider'          => 'openai',
             'ai_api_key'           => '',
             'ai_endpoint'          => '',
             'ai_model'             => '',
             'ai_prompt'            => RedmineExpertHelpdesk::AiClient::DEFAULT_PROMPT,
             'ai_max_input_chars'   => '12000',
             'ai_min_input_chars'   => '200',
             'ai_log_level'         => RedmineExpertHelpdesk::AiLogger::DEFAULT_LEVEL,
             'ai_max_output_tokens' => '500',
             'ai_timeout'           => '60',
             # Customer-facing answer draft (button in the note toolbar).
             # Own time budget, because this call - unlike all others - runs
             # synchronously in a web request: 60 s would hang a Puma thread and
             # also run into the reverse proxy's upstream timeout.
             'ai_answer_enabled'    => '0',
             'ai_answer_prompt'     => RedmineExpertHelpdesk::AnswerDrafter::DEFAULT_PROMPT,
             'ai_answer_min_score'  => RedmineExpertHelpdesk::AnswerDrafter::DRAFT_MIN_SCORE.to_s,
             'ai_answer_max_tokens' => '900',
             'ai_answer_timeout'    => '20',
             # Completeness check of incoming first mails ("follow-up").
             # Central master switch; mode and rules live per project.
             'info_request_enabled'   => '0',
             'info_request_subject'   => 'Уточнение по вашему обращению [#{{issue.id}}] {{issue.subject}}',
             'info_request_body'      => RedmineExpertHelpdesk::InfoRequestMailer::DEFAULT_BODY,
             'info_request_ai_prompt' => RedmineExpertHelpdesk::CompletenessCheck::DEFAULT_AI_PROMPT,
             'kb_enabled'         => '0',
             'kb_backend'         => 'qdrant',
             'kb_qdrant_url'      => '',
             'kb_qdrant_api_key'  => '',
             'kb_pg_url'          => '',
             'kb_embed_provider'  => 'openai',
             'kb_embed_model'     => 'text-embedding-3-small',
             'kb_embed_endpoint'  => '',
             'kb_embed_api_key'   => '',
             # Blank prompt = built-in prompt of the selected detail level.
             'kb_extract_detail'  => RedmineExpertHelpdesk::KnowledgeExtractor::DEFAULT_DETAIL,
             'kb_extract_prompt'  => '',
             'kb_top_k'           => '3',
             'kb_min_score'       => '0.5',
             'kb_min_results'     => '1',
             # Second stage: a cross-encoder over the vector store's shortlist.
             # Blank endpoint and key = same as kb_embed_* (bge-m3 and the
             # reranker sit on one base URL at the same provider).
             'kb_rerank_enabled'    => '0',
             'kb_rerank_model'      => RedmineExpertHelpdesk::AiClient::DEFAULT_RERANK_MODEL,
             'kb_rerank_endpoint'   => '',
             'kb_rerank_api_key'    => '',
             'kb_rerank_candidates' => '20',
             'kb_rerank_min_score'  => '0.2',
             'kb_rerank_timeout'    => '10',
             # Severity of the "mail sent" log line (failures are always errors).
             'mail_log_level'     => RedmineExpertHelpdesk::MailLogger::DEFAULT_LEVEL
           }

  project_module :helpdesk do
    permission :manage_helpdesk, {
      :helpdesk_mailboxes => [:new, :create, :edit, :update, :destroy,
                              :folders, :create_folder, :test_connection, :oauth_authorize],
      :helpdesk_oauth => [:authorize, :callback],
      :helpdesk_rules     => [:create, :destroy],
      :helpdesk_attachment_blacklists => [:preview, :create, :destroy],
      :helpdesk_reply_templates => [:index, :new, :create, :edit, :update, :destroy]
    }, :require => :member
    permission :fetch_helpdesk_mail, {
      :helpdesk_fetch => [:fetch]
    }, :require => :member
    permission :send_helpdesk_reply, {
      :helpdesk_replies  => [:create],
      :helpdesk_contacts => [:autocomplete],
      :helpdesk_init     => [:create],
      :helpdesk_note_content => [:create]
    }, :require => :member
    permission :view_helpdesk_info, {}, :read => true
    permission :manage_helpdesk_contacts, {
      :helpdesk_contacts => [:index, :edit, :update, :destroy, :autocomplete,
                             :toggle_info_request]
    }, :require => :member
    permission :view_helpdesk_sla_statistics, {
      :helpdesk_sla_statistics => [:index]
    }, :read => true
    # Ticket statistics (per agent / per customer figures): member roles only,
    # meant for a "helpdesk manager" role.
    permission :view_helpdesk_ticket_statistics, {
      :helpdesk_ticket_statistics => [:index]
    }, :require => :member
    # Knowledge base tab, three tiers (roles "KB viewer" / "KB editor" / "KB admin"):
    # read entries, correct/approve/reject them (re-embeds), delete + rebuild the index.
    permission :view_helpdesk_kb, {
      :helpdesk_kb_entries => [:index, :show]
    }, :read => true
    permission :edit_helpdesk_kb, {
      :helpdesk_kb_entries => [:new, :create, :edit, :update, :approve, :reject]
    }, :require => :member
    permission :manage_helpdesk_kb, {
      :helpdesk_kb_entries => [:destroy, :reindex, :reextract]
    }, :require => :member
  end

  # Global permission for the AI statistics (cost risk of the AI features).
  # Declared outside the project_module (:global => true) so it can be granted
  # to a role (e.g. "ai-admin") once and then applies across projects - without
  # project membership.
  permission :view_helpdesk_ai_statistics, {
    :helpdesk_ai_statistics => [:index]
  }, :global => true

  menu :project_menu, :helpdesk_contacts,
       { :controller => 'helpdesk_contacts', :action => 'index' },
       :caption  => :label_helpdesk_customers,
       :after    => :issues,
       :param    => :project_id,
       :if       => Proc.new { |p| p.module_enabled?(:helpdesk) }

  # SLA statistics tab only when SLA is active in the project
  menu :project_menu, :helpdesk_sla_statistics,
       { :controller => 'helpdesk_sla_statistics', :action => 'index' },
       :caption  => :label_helpdesk_sla_statistics,
       :after    => :helpdesk_contacts,
       :param    => :project_id,
       :if       => Proc.new { |p|
         p.module_enabled?(:helpdesk) &&
           HelpdeskProjectSetting.for_project(p).sla_enabled?
       }

  # Ticket statistics tab: helpdesk module enabled; the permission check is done
  # by the menu manager from the controller/action mapping (like the SLA tab).
  menu :project_menu, :helpdesk_ticket_statistics,
       { :controller => 'helpdesk_ticket_statistics', :action => 'index' },
       :caption  => :label_helpdesk_ticket_statistics,
       :after    => :helpdesk_sla_statistics,
       :param    => :project_id,
       :if       => Proc.new { |p| p.module_enabled?(:helpdesk) }

  # Knowledge base tab: helpdesk module on and the KB switched on globally; the menu
  # manager hides it for users without view_helpdesk_kb (controller/action mapping).
  menu :project_menu, :helpdesk_kb_entries,
       { :controller => 'helpdesk_kb_entries', :action => 'index' },
       :caption  => :label_helpdesk_kb,
       :after    => :helpdesk_ticket_statistics,
       :param    => :project_id,
       :if       => Proc.new { |p|
         p.module_enabled?(:helpdesk) && RedmineExpertHelpdesk::AiFeatures.kb_enabled?
       }

  # AI statistics tab: visible with the helpdesk module enabled, at least one of the AI/KB
  # features switched on globally (the page reports both kinds of request, so either one alone
  # makes it meaningful), and the global view_helpdesk_ai_statistics permission (role "ai-admin").
  # The permission check comes last — it is by far the most expensive of the three.
  menu :project_menu, :helpdesk_ai_statistics,
       { :controller => 'helpdesk_ai_statistics', :action => 'index' },
       :caption  => :label_helpdesk_ai_statistics,
       :after    => :helpdesk_ticket_statistics,
       :param    => :project_id,
       :if       => Proc.new { |p|
         p.module_enabled?(:helpdesk) &&
           RedmineExpertHelpdesk::AiFeatures.any_enabled? &&
           User.current.allowed_to?(:view_helpdesk_ai_statistics, nil, :global => true)
       }

  # Direct entry in the Administration menu (sidebar + admin overview) that links
  # straight to the plugin settings without going via "Plugins > Configure". Icon
  # depends on the version:
  #  - Redmine 6/7: SVG sprite icon from the plugin sprite (assets/images/icons.svg,
  #    symbol `icon--helpdesk`) via :icon + :plugin (render_single_menu_node calls
  #    sprite_icon(item.icon, plugin: item.plugin)).
  #  - Redmine 5: the old SVG sprites/`:icon` do not exist yet -> old CSS sprite
  #    icon via the `icon icon-*` class on the link.
  admin_menu_options = { :caption => :label_expert_helpdesk }
  if Redmine::VERSION::MAJOR >= 6
    admin_menu_options[:icon]   = 'helpdesk'
    admin_menu_options[:plugin] = 'redmine_expert_helpdesk'
    # The `icon` class is needed so the SVG inherits the blue currentColor stroke
    # of the other admin menu icons (without it, it stays at the .icon-svg default grey).
    admin_menu_options[:html]   = { :class => 'icon' }
  else
    admin_menu_options[:html] = { :class => 'icon icon-email' }
  end
  menu :admin_menu, :redmine_expert_helpdesk,
       { :controller => 'settings', :action => 'plugin', :id => 'redmine_expert_helpdesk' },
       admin_menu_options
end

# Apply patches directly: Redmine runs init.rb inside a to_prepare callback
# (PluginLoader#run_initializer) and reloads it on every reload in dev mode.
# Own to_prepare registrations from init.rb would never run in production,
# because the callbacks are already copied into the reloader by that point.
# project_settings_tabs is patched via an UnboundMethod capture (not prepend/super),
# so the Helpdesk tab coexists with alias_method_chain plugins
# (e.g. RedmineUP redmine_contacts_helpdesk). See projects_helper_patch.rb.
RedmineExpertHelpdesk::Patches::ProjectsHelperPatch.apply!(ProjectsHelper)
unless Project.included_modules.include?(RedmineExpertHelpdesk::Patches::ProjectPatch)
  Project.include(RedmineExpertHelpdesk::Patches::ProjectPatch)
end
unless Issue.included_modules.include?(RedmineExpertHelpdesk::Patches::IssuePatch)
  Issue.include(RedmineExpertHelpdesk::Patches::IssuePatch)
end
unless IssueQuery.ancestors.include?(RedmineExpertHelpdesk::Patches::IssueQueryPatch)
  IssueQuery.prepend(RedmineExpertHelpdesk::Patches::IssueQueryPatch)
end
# column_content also via an UnboundMethod capture (not prepend/super), so the
# SLA chip columns coexist with alias_method_chain plugins
# (e.g. RedmineUP redmine_contacts_helpdesk). See queries_helper_patch.rb.
RedmineExpertHelpdesk::Patches::QueriesHelperPatch.apply!(QueriesHelper)

# css_classes also via an UnboundMethod capture (see issue_css_classes_patch.rb):
# IssuePatch is included via include and cannot override the method.
RedmineExpertHelpdesk::Patches::IssueCssClassesPatch.apply!(Issue)

unless Journal.included_modules.include?(RedmineExpertHelpdesk::Patches::JournalPatch)
  Journal.include(RedmineExpertHelpdesk::Patches::JournalPatch)
end
# Make hd_icon_label globally available: Redmine sets include_all_helpers = false,
# so plugin helpers are not automatically included in core views.
# ApplicationHelper is available in all views.
unless ApplicationHelper.included_modules.include?(HelpdeskIconsHelper)
  ApplicationHelper.include(HelpdeskIconsHelper)
end

# Same for the answer template path helpers: they are needed from the project
# and plugin settings as well, i.e. from core views.
unless ApplicationHelper.included_modules.include?(HelpdeskReplyTemplatesHelper)
  ApplicationHelper.include(HelpdeskReplyTemplatesHelper)
end

# Activity feed: register incoming, outgoing and initial Helpdesk messages.
# As of Redmine 6 the plugin must be given so the feed loads the direction icons
# from the plugin sprite (assets/icons.svg): activity_event_type_icon -> sprite_icon(
# 'helpdesk-message-in', plugin: 'redmine_expert_helpdesk'). Without :plugin,
# Redmine::Activity.plugin_name returns nil and the icon is looked up in the core
# sprite (not present).
helpdesk_activity_options = { :class_name => 'HelpdeskMessage', :default => true }
helpdesk_activity_options[:plugin] = 'redmine_expert_helpdesk' if Redmine::VERSION::MAJOR >= 6
Redmine::Activity.register :helpdesk_messages, helpdesk_activity_options

# Adds the "Helpdesk" tab to the project settings.
#
# Deliberately via UnboundMethod capture instead of prepend/super: this lets the
# extension coexist with plugins that patch project_settings_tabs via
# alias_method_chain (e.g. RedmineUP redmine_contacts_helpdesk). prepend+super
# collides there ("super: no superclass method 'project_settings_tabs'"), because
# their alias_method captures the prepended method and the bare super then
# resolves to nothing. The explicit call of the cached original method is
# insensitive to ordering and chaining.
module RedmineExpertHelpdesk
  module Patches
    module ProjectsHelperPatch
      def self.apply!(base)
        return if base.instance_variable_get(:@expert_helpdesk_tabs_patched)

        original = base.instance_method(:project_settings_tabs)
        base.send(:define_method, :project_settings_tabs) do
          tabs = original.bind(self).call
          if User.current.allowed_to?(:manage_helpdesk, @project)
            # Tab name deliberately 'expert_helpdesk' (not 'helpdesk'): RedmineUP
            # redmine_contacts_helpdesk also registers a tab named
            # 'helpdesk'; identical names collide (same DOM id, only one
            # tab shows the correct content). Internal redirects use
            # the same name (:tab => 'expert_helpdesk').
            tabs << {
              :name    => 'expert_helpdesk',
              :action  => :manage_helpdesk,
              :partial => 'projects/settings/helpdesk',
              :label   => :label_expert_helpdesk
            }
          end
          tabs
        end
        base.instance_variable_set(:@expert_helpdesk_tabs_patched, true)
      end
    end
  end
end

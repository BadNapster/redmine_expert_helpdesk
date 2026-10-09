# Renders the SLA grid columns (reaction/solution) as colored traffic-light chips,
# reusing the hd-sla-* styles from helpdesk_activity.css (included on every page
# via view_layouts_base_html_head). Other columns unchanged.
#
# Deliberately via UnboundMethod capture instead of prepend/super (analogous to
# ProjectsHelperPatch): this lets column_content coexist with plugins that patch it via
# alias_method_chain (e.g. RedmineUP redmine_contacts_helpdesk).
# prepend+super collides there ("super: no superclass method 'column_content'"),
# because their alias_method captures the prepended method and the bare super then
# resolves to nothing. The explicit call of the cached original method is
# insensitive to ordering and chaining.
module RedmineExpertHelpdesk
  module Patches
    module QueriesHelperPatch
      SLA_COLUMNS = [:helpdesk_sla_reaction, :helpdesk_sla_solution].freeze

      SLA_CSS = {
        :met           => 'hd-sla-met',
        :running       => 'hd-sla-running',
        :warning       => 'hd-sla-warning',
        :breached      => 'hd-sla-breached',
        :breached_done => 'hd-sla-breached'
      }.freeze

      def self.apply!(base)
        return if base.instance_variable_get(:@expert_helpdesk_column_content_patched)

        original = base.instance_method(:column_content)
        base.send(:define_method, :column_content) do |column, item|
          if column.name == :helpdesk_awaiting_agent && item.is_a?(Issue)
            awaiting = item.helpdesk_awaiting_agent
            next ''.html_safe if awaiting.nil?

            since, reason = awaiting
            label = l("label_helpdesk_awaiting_#{reason == 'reopen' ? 'reopen' : 'reply'}")
            next content_tag(:span,
                             safe_join([label, ' (', time_tag(since), ')']),
                             :class => 'hd-sla-chip hd-awaiting-chip')
          end

          unless SLA_COLUMNS.include?(column.name) && item.is_a?(Issue)
            next original.bind(self).call(column, item)
          end

          status = item.send(column.name)
          next ''.html_safe if status.nil?

          content_tag(:span, l("label_helpdesk_sla_#{status}"),
                      :class => "hd-sla-chip #{SLA_CSS[status]}")
        end
        base.instance_variable_set(:@expert_helpdesk_column_content_patched, true)
      end
    end
  end
end

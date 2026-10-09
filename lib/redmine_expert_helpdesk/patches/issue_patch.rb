# Extends Issue with:
# - helpdesk_kunde / helpdesk_kunde_email: the ticket's customer contact
#   (display name resp. email only); grid columns "Kunde" / "Kunden-E-Mail"
# - helpdesk_sla_reaction / helpdesk_sla_solution: SLA status per clock, from
#   the precomputed deadlines; grid columns/filters "SLA reaction/solution"
# - after_save: keeps the precomputed SLA deadlines current
module RedmineExpertHelpdesk
  module Patches
    module IssuePatch
      def self.included(base)
        # The issue owns its helpdesk data. Without these, deleting an issue
        # through core Redmine (issue page, bulk delete, project delete) left
        # its ticket-info row behind and its messages pointing at an issue_id
        # that no longer exists; only the plugin's own API delete cleaned up
        # (#47). Messages go too: issue_id is NOT NULL and the model requires
        # an issue, and the ticket and its archived .eml are deleted anyway.
        # (The API path tried to unlink them instead, which raised on every
        # ticket that had mail.)
        base.has_one :helpdesk_ticket_info, :dependent => :delete
        base.has_many :helpdesk_messages, :dependent => :delete_all
        base.after_save :helpdesk_refresh_sla_deadlines
        base.after_save :helpdesk_enqueue_kb_ingest
        base.after_save :helpdesk_clear_awaiting_on_close
      end

      # The ticket's customer contact: the authoritative HelpdeskTicketInfo link
      # first (set on mail ingest, manual init assignment and legacy import),
      # falling back to the sender of the first incoming mail for legacy tickets
      # without a ticket-info row. nil when the ticket has no customer (e.g.
      # agent-created without an assigned contact) -- that is expected.
      # Wrapped in an array so a nil result is memoized too; both customer grid
      # columns hit this once per row (mirrors helpdesk_awaiting_agent).
      def helpdesk_customer_contact
        @helpdesk_customer_contact ||= begin
          contact = HelpdeskTicketInfo.for_issue(self)&.helpdesk_contact
          contact ||= HelpdeskMessage
                        .joins(:helpdesk_contact)
                        .where(:issue_id => id, :direction => 'in')
                        .order(:id => :asc)
                        .first&.helpdesk_contact
          [contact]
        end
        @helpdesk_customer_contact.first
      end

      # Display name of the customer contact (grid column "Kunde"), or nil.
      def helpdesk_kunde
        helpdesk_customer_contact&.display_name
      end

      # Email address of the customer contact (grid column "Kunden-E-Mail"), or
      # nil. Separate column because display names can be long and unclear.
      def helpdesk_kunde_email
        helpdesk_customer_contact&.email
      end

      # SLA status of the reaction clock (nil when no SLA applies). Without a recorded
      # first reaction, the closing time counts as completion for closed tickets
      # (the reaction does not keep running beyond the resolution).
      def helpdesk_sla_reaction
        info = HelpdeskTicketInfo.for_issue(self)
        return nil unless info

        done = info.first_response_at || (closed? ? closed_on : nil)
        RedmineExpertHelpdesk::Sla.clock_status_from(
          info.sla_reaction_due_at, info.sla_reaction_warn_at, done)
      end

      # SLA status of the solution clock (nil when no SLA applies).
      def helpdesk_sla_solution
        info = HelpdeskTicketInfo.for_issue(self)
        return nil unless info

        done = closed? ? closed_on : nil
        RedmineExpertHelpdesk::Sla.clock_status_from(
          info.sla_solution_due_at, info.sla_solution_warn_at, done)
      end

      # [since, reason] when a customer is waiting for an answer, otherwise nil.
      # Wrapped in an array so a nil result is memoized too -- this is hit once per
      # grid row by both column_content and css_classes.
      def helpdesk_awaiting_agent
        @helpdesk_awaiting_agent ||= begin
          info = HelpdeskTicketInfo.awaiting_agent_enabled? ? HelpdeskTicketInfo.for_issue(self) : nil
          [info&.awaiting_agent_since ? [info.awaiting_agent_since, info.awaiting_agent_reason] : nil]
        end
        @helpdesk_awaiting_agent.first
      end

      # Closing a ticket answers the customer even without a note. At the model
      # (after_save) so bulk and API changes are caught too -- same reasoning as the
      # KB ingest below.
      def helpdesk_clear_awaiting_on_close
        return unless saved_change_to_status_id? && closed?
        return unless project&.module_enabled?(:helpdesk)

        HelpdeskTicketInfo.clear_awaiting_agent!(self)
      rescue StandardError => e
        Rails.logger.warn("Helpdesk: clear_awaiting_on_close failed (Issue ##{id}): #{e.message}")
      end

      # Update the precomputed deadlines after saving, but only when relevant
      # (new, priority changed or not yet computed), so the business-hours loop
      # is not run on every save.
      def helpdesk_refresh_sla_deadlines
        return unless project&.module_enabled?(:helpdesk)

        relevant = saved_change_to_id? || saved_change_to_priority_id? ||
                   HelpdeskTicketInfo.for_issue(self)&.sla_reaction_due_at.nil?
        return unless relevant

        RedmineExpertHelpdesk::Sla.refresh_deadlines!(self)
      end

      # On close, add the solved ticket to the knowledge base (async).
      # At the model (after_save) so that bulk changes and API/script changes
      # are captured too, not just single updates through the
      # controller. Errors must not abort the save.
      def helpdesk_enqueue_kb_ingest
        return unless saved_change_to_status_id? && closed?
        return unless project&.module_enabled?(:helpdesk)
        return unless RedmineExpertHelpdesk::AiFeatures.kb_enabled?

        ps = HelpdeskProjectSetting.for_project(project)
        return if ps.kb_ingest_mode.to_s == 'off'

        HelpdeskKnowledgeIngestJob.perform_later(id)
      rescue StandardError => e
        Rails.logger.warn("Helpdesk: KB enqueue (after_save) failed (Issue ##{id}): #{e.message}")
      end
    end
  end
end

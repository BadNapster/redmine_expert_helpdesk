# Absolute due timestamps per SLA clock (precomputed from business minutes +
# working hours). Enables sort/filter columns in the ticket grid
# by plain timestamp comparison against the current time (without business-hours
# calculation at query time). warn_at = due at 80 % of the target time.
class AddSlaDeadlinesToHelpdeskTicketInfos < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_ticket_infos, :bulk => true do |t|
      t.datetime :sla_reaction_due_at  unless column_exists?(:helpdesk_ticket_infos, :sla_reaction_due_at)
      t.datetime :sla_reaction_warn_at unless column_exists?(:helpdesk_ticket_infos, :sla_reaction_warn_at)
      t.datetime :sla_solution_due_at  unless column_exists?(:helpdesk_ticket_infos, :sla_solution_due_at)
      t.datetime :sla_solution_warn_at unless column_exists?(:helpdesk_ticket_infos, :sla_solution_warn_at)
    end
  end
end

# SLA core logic: resolve target times (priority override -> project default),
# compute clock status and record tracking events.
#
# Status per clock:
#   :met           - done within the target time
#   :breached_done - done, but target time exceeded
#   :running       - running, < 80 % of the target time used
#   :warning       - running, >= 80 % of the target time used
#   :breached      - running, target time exceeded
module RedmineExpertHelpdesk
  class Sla
    WARNING_RATIO = 0.8

    # SLA applies to a ticket when: enabled in the project AND the ticket was
    # created after enabling (prevents all existing tickets from turning "red"
    # immediately when it is switched on).
    def self.enabled_for?(issue, setting = nil)
      setting ||= HelpdeskProjectSetting.for_project(issue.project)
      return false unless setting.persisted? && setting.sla_enabled?
      return false if setting.sla_enabled_at.present? && issue.created_on < setting.sla_enabled_at

      true
    end

    # Target times in business minutes: priority override before project default.
    def self.targets_for(issue, setting = nil)
      setting ||= HelpdeskProjectSetting.for_project(issue.project)
      override = HelpdeskSlaPriority.find_by(:project_id => issue.project_id, :priority_id => issue.priority_id)
      {
        :reaction => override&.reaction_minutes.presence || setting.sla_reaction_minutes,
        :solution => override&.solution_minutes.presence || setting.sla_solution_minutes
      }
    end

    # Overall status of both clocks, nil when SLA does not apply.
    def self.state_for(issue, info = nil)
      setting = HelpdeskProjectSetting.for_project(issue.project)
      return nil unless enabled_for?(issue, setting)

      info  ||= HelpdeskTicketInfo.for_issue(issue)
      targets = targets_for(issue, setting)
      solution_done_at = issue.closed? ? issue.closed_on : nil

      # The reaction clock ends at the latest when the ticket is solved/closed: if
      # no first reaction was recorded, the closing time counts as completion
      # (otherwise the reaction clock would keep running on closed tickets forever
      # and could never be met/exceeded).
      first_response = info&.first_response_at
      reaction_done_at = first_response || solution_done_at
      reaction_minutes = first_response ? info&.reaction_business_minutes : nil

      {
        :reaction => clock_state(issue, targets[:reaction], reaction_done_at,
                                 reaction_minutes, setting),
        :solution => clock_state(issue, targets[:solution], solution_done_at,
                                 info&.solution_business_minutes, setting)
      }
    end

    # Status of a single clock, nil when no target is configured.
    def self.clock_state(issue, target_minutes, done_at, done_minutes, setting)
      target = target_minutes.to_i
      return nil if target <= 0

      bh = BusinessHours.new(setting)

      if done_at.present?
        minutes = done_minutes || bh.elapsed_minutes(issue.created_on, done_at)
        {
          :status  => minutes <= target ? :met : :breached_done,
          :minutes => minutes,
          :target  => target
        }
      else
        elapsed = bh.elapsed_minutes(issue.created_on, Time.current)
        status  = if elapsed > target
                    :breached
                  elsif elapsed >= (target * WARNING_RATIO).floor
                    :warning
                  else
                    :running
                  end
        {
          :status  => status,
          :minutes => elapsed,
          :target  => target,
          :due_at  => bh.due_at(issue.created_on, target)
        }
      end
    end

    # --- Precomputed deadlines (for ticket grid columns/filters) -------------

    # Computes and stores the absolute deadline timestamps of both clocks on the
    # HelpdeskTicketInfo row. Values are cleared when SLA is no longer valid.
    # Reuses BusinessHours#due_at and targets_for.
    def self.refresh_deadlines!(issue, info = nil)
      setting = HelpdeskProjectSetting.for_project(issue.project)
      info  ||= HelpdeskTicketInfo.for_issue(issue)

      unless enabled_for?(issue, setting)
        return if info.nil?

        info.assign_attributes(:sla_reaction_due_at => nil, :sla_reaction_warn_at => nil,
                               :sla_solution_due_at => nil, :sla_solution_warn_at => nil)
        info.save! if info.persisted? && info.changed?
        return
      end

      info  ||= HelpdeskTicketInfo.find_or_initialize_by(:issue_id => issue.id)
      targets = targets_for(issue, setting)
      bh      = BusinessHours.new(setting)
      r       = targets[:reaction].to_i
      s       = targets[:solution].to_i

      info.sla_reaction_due_at  = r > 0 ? bh.due_at(issue.created_on, r) : nil
      info.sla_reaction_warn_at = r > 0 ? bh.due_at(issue.created_on, (r * WARNING_RATIO).floor) : nil
      info.sla_solution_due_at  = s > 0 ? bh.due_at(issue.created_on, s) : nil
      info.sla_solution_warn_at = s > 0 ? bh.due_at(issue.created_on, (s * WARNING_RATIO).floor) : nil

      info.save! if info.changed?
    rescue StandardError => e
      Rails.logger.warn "Helpdesk/SLA: refresh_deadlines for ticket ##{issue.id} failed: #{e.message}"
    end

    # Cheaper status of a clock from the stored timestamps (mirrors the
    # SQL CASE logic of the grid columns, without the business-hours loop). nil = no SLA.
    def self.clock_status_from(due_at, warn_at, done_at)
      return nil if due_at.nil?

      if done_at.present?
        done_at <= due_at ? :met : :breached_done
      else
        now = Time.current
        if now > due_at
          :breached
        elsif warn_at && now >= warn_at
          :warning
        else
          :running
        end
      end
    end

    # Recompute the deadlines of all open, SLA-relevant tickets of a project
    # (after project/priority settings changed).
    def self.refresh_project_deadlines!(project)
      Issue.open.where(:project_id => project.id).find_each do |issue|
        refresh_deadlines!(issue)
      end
    end

    # --- Tracking events -----------------------------------------------------

    # Records the first reaction (public agent note or customer reply mail).
    #
    # Recorded regardless of SLA: the ticket statistics need first_response_at for
    # every helpdesk ticket. Only the business-minute figure and the deadline
    # machinery are SLA features. Without SLA the row is never created here (that
    # would turn every issue of every project into a "helpdesk ticket" on its first
    # public note) - only an existing HelpdeskTicketInfo row gets the timestamp.
    # Write-once: a later note never moves the first reaction; the check and the
    # write happen under a row lock so two concurrent replies cannot both win.
    # `by` is the acting user (nil/anonymous/non-user leaves first_response_by_id
    # empty); the ticket statistics attribute the first response to it without
    # depending on a journal note.
    def self.record_first_response!(issue, at, by: User.current)
      setting = HelpdeskProjectSetting.for_project(issue.project)
      sla     = setting.persisted? && setting.sla_enabled?

      info = sla ? HelpdeskTicketInfo.find_or_create_by!(:issue_id => issue.id)
                 : HelpdeskTicketInfo.for_issue(issue)
      return if info.nil?

      info.with_lock do
        next if info.first_response_at.present?

        info.first_response_at    = at
        info.first_response_by_id = by.id if by.is_a?(User) && !by.anonymous?
        info.reaction_business_minutes = BusinessHours.new(setting).elapsed_minutes(issue.created_on, at) if sla
        info.save!
      end
    rescue StandardError => e
      Rails.logger.warn "Helpdesk/SLA: record_first_response for ticket ##{issue.id} failed: #{e.message}"
    end

    # Compute the solution time on close, or reset it on reopen.
    def self.sync_solution!(issue)
      setting = HelpdeskProjectSetting.for_project(issue.project)
      return unless setting.persisted? && setting.sla_enabled?

      info = HelpdeskTicketInfo.find_or_initialize_by(:issue_id => issue.id)

      if issue.closed? && issue.closed_on.present?
        return if info.solution_business_minutes.present?

        info.solution_business_minutes = BusinessHours.new(setting).elapsed_minutes(issue.created_on, issue.closed_on)
      else
        return if info.solution_business_minutes.nil? && info.sla_solution_notified_at.nil?

        info.solution_business_minutes = nil
        info.sla_solution_notified_at  = nil
      end
      info.save!
    rescue StandardError => e
      Rails.logger.warn "Helpdesk/SLA: sync_solution for ticket ##{issue.id} failed: #{e.message}"
    end
  end
end

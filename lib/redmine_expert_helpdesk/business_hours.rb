# Business-hours calculator for the SLA clocks.
# Working hours come from HelpdeskProjectSetting: weekdays (ISO, Mon=1..Sun=7)
# and a time span (HH:MM to HH:MM). SLA times only run within
# these windows.
module RedmineExpertHelpdesk
  class BusinessHours
    MAX_LOOKAHEAD_DAYS = 400

    def initialize(setting)
      @days      = setting.sla_work_days_array
      @start_min = parse_hhmm(setting.sla_work_start, 8 * 60)
      @end_min   = parse_hhmm(setting.sla_work_end, 17 * 60)
      @end_min   = @start_min if @end_min < @start_min
    end

    # Business minutes between two points in time (>= 0).
    def elapsed_minutes(from, to)
      return 0 if from.nil? || to.nil? || to <= from

      total = 0
      date  = from.getlocal.to_date
      while date <= to.getlocal.to_date
        if workday?(date)
          seg_start = [from, time_on(date, @start_min)].max
          seg_end   = [to,   time_on(date, @end_min)].min
          total += ((seg_end - seg_start) / 60).floor if seg_end > seg_start
        end
        date += 1
      end
      total
    end

    # Point in time at which +minutes+ business minutes have elapsed from +from+
    # (due date). Returns nil when no working days are configured.
    def due_at(from, minutes)
      return nil if from.nil? || minutes.to_i <= 0 || @days.empty?

      remaining = minutes.to_i
      date   = from.getlocal.to_date
      cursor = from

      MAX_LOOKAHEAD_DAYS.times do
        if workday?(date)
          day_start = time_on(date, @start_min)
          day_end   = time_on(date, @end_min)
          seg_start = [cursor, day_start].max

          if seg_start < day_end
            available = ((day_end - seg_start) / 60).floor
            return seg_start + remaining * 60 if remaining <= available

            remaining -= available
          end
        end
        date  += 1
        cursor = time_on(date, 0)
      end
      nil
    end

    def workday?(date)
      @days.include?(date.cwday)
    end

    private

    def parse_hhmm(value, default_minutes)
      m = value.to_s.match(/\A(\d{1,2}):(\d{2})\z/)
      return default_minutes unless m

      [[m[1].to_i, 23].min * 60 + [m[2].to_i, 59].min, 0].max
    end

    # Point in time on +date+ at +minutes_from_midnight+ in the LOCAL time zone of
    # the server. Business hours (e.g. 08:00-17:00) are local office hours and must
    # hold regardless of the ambient Time.zone: in background jobs (SLA cron) and
    # for users without a time zone setting, Time.zone is often UTC, which would
    # wrongly shift the office hours to UTC (e.g. 08:00 as 08:00 UTC = 10:00
    # local). The display also uses the local server time, so this is consistent.
    def time_on(date, minutes_from_midnight)
      Time.local(date.year, date.month, date.day) + minutes_from_midnight * 60
    end
  end
end

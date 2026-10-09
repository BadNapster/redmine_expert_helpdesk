# View helpers for the SLA statistics (KPI time format, weekday names).
module HelpdeskSlaStatisticsHelper
  # Business minutes as "Xh Ym" (or "Ym"); nil -> dash.
  def hd_stats_minutes(minutes)
    return content_tag(:span, '–', :class => 'hd-stats-empty') if minutes.nil?

    m = minutes.to_i
    h, rest = m.divmod(60)
    h > 0 ? "#{h}h #{rest}m" : "#{rest}m"
  end

  # ISO weekday name (1=Mon .. 7=Sun) from the Redmine localization.
  def hd_stats_weekday_name(iso_wday)
    day_name((iso_wday % 7)) # Redmine day_name: 0=Sun..6=Sat
  end
end

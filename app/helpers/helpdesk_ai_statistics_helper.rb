# View helpers for the AI statistics (number/duration/ratio formatting).
module HelpdeskAiStatisticsHelper
  # Integer with thousands separator; nil -> dash.
  def hd_ai_number(value)
    return content_tag(:span, '–', :class => 'hd-stats-empty') if value.nil?

    number_with_delimiter(value.to_i)
  end

  # Latency in ms as "X ms" / "X.Y s"; nil -> dash.
  def hd_ai_latency(ms)
    return content_tag(:span, '–', :class => 'hd-stats-empty') if ms.nil?

    ms = ms.to_i
    ms < 1000 ? "#{ms} ms" : "#{(ms / 1000.0).round(1)} s"
  end

  # Ratio (0..100) as "X %"; nil -> dash.
  def hd_ai_ratio(pct)
    return content_tag(:span, '–', :class => 'hd-stats-empty') if pct.nil?

    "#{pct} %"
  end

  # Localized name of a request type (summary, kb_extract, ...).
  def hd_ai_type_label(type)
    l("label_helpdesk_ai_stats_type_#{type}", :default => type.to_s)
  end

  # ISO weekday name (1=Mon .. 7=Sun) from the Redmine localization.
  def hd_ai_weekday_name(iso_wday)
    day_name((iso_wday % 7)) # Redmine day_name: 0=Sun..6=Sat
  end
end

# Shared date-range logic of the statistics pages (SLA and AI statistics):
# presets plus a custom From/To range. Expects an @period (grouping
# day/week/month/year) for the 'custom' default. Included via `include`.
module HelpdeskStatsDateRange
  # Selectable ranges; 'custom' shows the date fields.
  RANGES = %w[last_7_days last_30_days last_90_days last_6_months last_12_months last_5_years custom].freeze

  private

  # The selected range. If not given: default (year view), but explicit
  # date parameters (e.g. link/bookmark) count as 'custom'.
  def resolve_range
    r = params[:range].presence
    return r if RANGES.include?(r)

    params[:date_from].present? ? 'custom' : 'last_12_months'
  end

  # Returns [date_to, date_from] for the selected range.
  def range_dates(range)
    to = Date.current
    case range
    when 'last_7_days'    then [to, to - 7]
    when 'last_30_days'   then [to, to - 30]
    when 'last_90_days'   then [to, to - 90]
    when 'last_6_months'  then [to, to.prev_month(6)]
    when 'last_12_months' then [to, to.prev_month(12)]
    when 'last_5_years'   then [to, to.prev_year(5)]
    else # custom
      dto = parse_date(params[:date_to]) || Date.current
      [dto, parse_date(params[:date_from]) || default_from(@period, dto)]
    end
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # A sensible default range per grouping (only for 'custom' without a From date).
  def default_from(period, to)
    case period
    when 'day'  then to - 30
    when 'week' then to - 7 * 12
    when 'year' then to - 365 * 5
    else             to.prev_month(12)
    end
  end
end

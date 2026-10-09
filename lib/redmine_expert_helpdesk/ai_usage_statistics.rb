# Aggregates metrics for the AI statistics page of a project.
#
# Basis: the usage log (HelpdeskAiRequest) - every AI call (summary, KB
# extraction, embedding, RAG retrieval) with provider/model, tokens, duration and
# success/failure. Grouping by day/week/month/year; time buckets/"peak times" in
# local server time (consistent with SlaStatistics).
#
# Returns plain Ruby data structures (to_h) without any rendering logic, so the
# aggregation stays testable in isolation. Bucketing/averages come from
# StatisticsSupport.
module RedmineExpertHelpdesk
  class AiUsageStatistics
    include StatisticsSupport

    PERIODS = StatisticsSupport::PERIODS

    Row = Struct.new(:id, :request_type, :provider, :model,
                     :input_tokens, :output_tokens, :duration_ms, :success, :error_class, :created_at)

    def initialize(project, period: 'month', date_from: nil, date_to: nil)
      @project = project
      @period  = StatisticsSupport.normalize_period(period)
      @date_to   = date_to   || Date.current
      @date_from = date_from || (@date_to - 30)
      @date_from, @date_to = @date_to, @date_from if @date_from > @date_to

      @from_t = @date_from.to_time         # local midnight (start inclusive)
      @to_t   = (@date_to + 1).to_time     # local midnight of the next day (end exclusive)
    end

    def to_h
      rows = load_rows
      {
        :period    => @period,
        :date_from => @date_from,
        :date_to   => @date_to,
        :totals    => totals(rows),
        :by_type   => by_type(rows),
        :by_model  => by_model(rows),
        :volume    => volume_series(rows),
        :errors    => errors(rows),
        :busiest_hours    => busiest_hours(rows),
        :busiest_weekdays => busiest_weekdays(rows),
        :kb        => kb_counts
      }
    end

    private

    def load_rows
      HelpdeskAiRequest
        .where(:project_id => @project.id)
        .where("created_at >= ? AND created_at < ?", @from_t, @to_t)
        .pluck(:id, :request_type, :provider, :model,
               :input_tokens, :output_tokens, :duration_ms, :success, :error_class, :created_at)
        .map { |r| Row.new(*r) }
    end

    def totals(rows)
      success = rows.count(&:success)
      failed  = rows.size - success
      input   = rows.sum { |r| r.input_tokens.to_i }
      output  = rows.sum { |r| r.output_tokens.to_i }
      durations = rows.select(&:success).filter_map(&:duration_ms)
      {
        :requests      => rows.size,
        :success       => success,
        :failed        => failed,
        :success_ratio => rows.any? ? (success * 100.0 / rows.size).round(1) : nil,
        :input_tokens  => input,
        :output_tokens => output,
        :total_tokens  => input + output,
        :avg_latency_ms => mean(durations),
        :p95_latency_ms => percentile(durations, 95),
        :summaries     => rows.count { |r| r.request_type == 'summary' },
        # Explicit prefix match: "everything that is not a summary" used to be the
        # KB counter, which would now silently absorb the completeness checks too.
        :kb_requests   => rows.count { |r| r.request_type.to_s.start_with?('kb_') }
      }
    end

    # Breakdown by request type (fixed order, only types that exist).
    def by_type(rows)
      grouped = rows.group_by(&:request_type)
      HelpdeskAiRequest::REQUEST_TYPES.filter_map do |type|
        rs = grouped[type]
        next unless rs
        { :type => type, :requests => rs.size,
          :tokens => rs.sum { |r| r.input_tokens.to_i + r.output_tokens.to_i },
          :failed => rs.count { |r| !r.success } }
      end
    end

    # Breakdown by provider/model, descending by count.
    def by_model(rows)
      rows.group_by { |r| [r.provider, r.model] }.map do |(provider, model), rs|
        { :provider => provider, :model => model,
          :label    => [provider, model].reject { |v| v.to_s.empty? }.join(' · ').presence || '–',
          :requests => rs.size,
          :tokens   => rs.sum { |r| r.input_tokens.to_i + r.output_tokens.to_i } }
      end.sort_by { |h| -h[:requests] }
    end

    # Count/tokens per bucket, including empty buckets, so the bars are gap-free.
    def volume_series(rows)
      requests = Hash.new(0)
      input    = Hash.new(0)
      output   = Hash.new(0)
      failed   = Hash.new(0)
      rows.each do |r|
        key = bucket_key(r.created_at)
        requests[key] += 1
        input[key]    += r.input_tokens.to_i
        output[key]   += r.output_tokens.to_i
        failed[key]   += 1 unless r.success
      end
      ordered_buckets.map do |key, label|
        { :key => key, :label => label, :requests => requests[key],
          :input_tokens => input[key], :output_tokens => output[key], :failed => failed[key] }
      end
    end

    # Errors by error class, descending.
    def errors(rows)
      rows.reject(&:success).group_by { |r| r.error_class.presence || '–' }
          .map { |cls, rs| { :error_class => cls, :count => rs.size } }
          .sort_by { |h| -h[:count] }
    end

    def busiest_hours(rows)
      StatisticsSupport.hour_histogram(rows.map(&:created_at))
    end

    # ISO weekdays 1=Mon .. 7=Sun.
    def busiest_weekdays(rows)
      StatisticsSupport.weekday_histogram(rows.map(&:created_at))
    end

    # States of the project's knowledge-base entries in the period.
    def kb_counts(*)
      base = { 'pending' => 0, 'approved' => 0, 'skipped' => 0 }
      counts = HelpdeskKnowledgeEntry
                 .where(:project_id => @project.id)
                 .where("created_at >= ? AND created_at < ?", @from_t, @to_t)
                 .group(:status).count
      base.merge(counts).transform_keys(&:to_sym)
    end
  end
end

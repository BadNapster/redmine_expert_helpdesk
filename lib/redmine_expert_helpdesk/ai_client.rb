# AI client for summarising incoming helpdesk mails.
#
# Supports three providers (configured centrally in the plugin settings):
#   - openai    : OpenAI Chat Completions (Authorization: Bearer)
#   - anthropic : Anthropic Messages API (x-api-key + anthropic-version)
#   - custom    : any OpenAI-compatible endpoint (self-hosted:
#                 Ollama, vLLM, LocalAI, LM Studio ...) via base URL
#
# HTTP as in GraphClient via the Ruby standard library (Net::HTTP), no extra gem,
# no retry. Errors are raised as AiError; the calling job catches them
# and does not break mail processing.

require 'net/http'
require 'uri'
require 'json'

module RedmineExpertHelpdesk
  class AiClient
    class AiError < StandardError
      attr_reader :status, :body

      def initialize(message, status = nil, body = nil)
        super(message)
        @status = status
        @body = body
      end
    end

    class ConfigurationError < AiError; end

    # The service was unreachable (timeout, DNS, TLS, connection refused) - as
    # opposed to a request the provider rejected on its merits. The operator can
    # act on the difference: either try again right away, or look at the
    # settings.
    class TransportError < AiError; end

    # The provider answered, but with no text. Reasoning models do this when
    # they spend the whole output on reasoning_content (prod issue #936648).
    class EmptyResponseError < AiError; end

    PROVIDERS = %w[openai anthropic custom].freeze

    DEFAULT_ENDPOINTS = {
      'openai'    => 'https://api.openai.com/v1',
      'anthropic' => 'https://api.anthropic.com'
    }.freeze

    ANTHROPIC_VERSION = '2023-06-01'.freeze

    # Solid Russian default prompt (agent-facing). Stored centrally as the
    # plugin settings default and can be extended or overridden per project
    # (HelpdeskProjectSetting#effective_ai_prompt).
    DEFAULT_PROMPT = <<~PROMPT.freeze
      Ты — ассистент в технической поддержке (Helpdesk). Составь для сотрудников
      поддержки краткую сводку входящего сообщения клиента. Сообщение может быть
      пересланным письмом или целой перепиской, в которой важная информация
      разбросана по разным письмам.

      Сообщение начинается со строки темы («Тема: ...»). Она является частью
      сообщения клиента — данные из нее (система, устройство, ошибка, сроки)
      включаются в сводку так же, как и данные из текста.

      Выдай краткую сводку на русском языке в виде пунктов. Называй только
      соответствующие пункты и ничего не выдумывай:
      - Обращение: какова настоящая проблема/запрос клиента?
      - Пожелание: чего конкретно клиент хочет добиться?
      - Что уже пробовали: упомянутые ранее попытки решения/шаги.
      - Важные факты: тексты ошибок, сроки, затронутые системы, номера.
      - Вложения: если упомянуты/содержатся релевантные вложения, кратко укажи.

      Отвечай исключительно сводкой, без обращения и без заключительной формулы.
    PROMPT

    # Token usage of the last summarize call: { :input => Integer|nil, :output => Integer|nil }.
    attr_reader :last_usage

    # Why the model stopped ('stop', 'length', ...), normalised across both
    # providers. Without it, an answer cut off at max_output_tokens is
    # indistinguishable from a complete one - cosmetic for a summary, but in a
    # customer mail it is half a sentence that reads like a commitment.
    attr_reader :last_finish_reason

    def initialize(settings = nil)
      @settings = settings || Setting.plugin_redmine_expert_helpdesk
      @last_usage = {}
    end

    def enabled?
      @settings['ai_enabled'].to_s == '1'
    end

    def provider
      p = @settings['ai_provider'].to_s.strip
      PROVIDERS.include?(p) ? p : 'openai'
    end

    def model
      @settings['ai_model'].to_s.strip
    end

    def api_key
      @settings['ai_api_key'].to_s.strip
    end

    # Base URL: blank = provider default; it is mandatory for the custom provider.
    def endpoint
      @settings['ai_endpoint'].to_s.strip.presence || DEFAULT_ENDPOINTS[provider]
    end

    def configured?
      return false unless api_key.present? && model.present?
      return false if provider == 'custom' && @settings['ai_endpoint'].to_s.strip.blank?

      true
    end

    def max_output_tokens
      v = @settings['ai_max_output_tokens'].to_i
      v.positive? ? v : 500
    end

    def read_timeout
      v = @settings['ai_timeout'].to_i
      v.positive? ? v : 60
    end

    # Produces a summary.
    #   system_prompt : instructions to the model
    #   user_text     : mail content (optionally including history and attachment text)
    #   image_parts   : [{ :content_type => 'image/png', :data => '<base64>' }] (Vision)
    # Returns the summary text (String) or raises AiError.
    #   log_context : optional { :request_type, :project_id, :issue_id } - when set,
    #                 the call (success or failure) is recorded in
    #                 HelpdeskAiRequest.
    #   disable_thinking : ask the model to skip its reasoning phase. Only the
    #                 custom provider sends anything (see thinking_params).
    def summarize(system_prompt, user_text, image_parts = [], log_context: nil, disable_thinking: false)
      raise ConfigurationError, 'AI is not configured (API key, model or endpoint missing)' unless configured?

      # Reset so a call never inherits the previous one's stop reason.
      @last_finish_reason = nil
      with_request_log(log_context, :provider => provider, :model => model, :default_type => 'summary') do
        if provider == 'anthropic'
          summarize_anthropic(system_prompt, user_text, image_parts)
        else # openai + custom (OpenAI-kompatibel)
          summarize_openai(system_prompt, user_text, image_parts, disable_thinking)
        end
      end
    end

    # Request fields that switch off a model's reasoning mode. Only the custom
    # provider gets one: vLLM and SGLang hand chat_template_kwargs to the chat
    # template, where Qwen3-style models read enable_thinking, and other
    # OpenAI-compatible servers ignore the unknown field. Official OpenAI
    # rejects reasoning_effort with HTTP 400 on non-reasoning models
    # (gpt-4o-mini ...), and Anthropic only thinks when asked to, which we
    # never do - so both get nothing.
    # Whether disable_thinking changes the request at all (see thinking_params).
    def can_disable_thinking?
      thinking_params(true).any?
    end

    def thinking_params(disable_thinking)
      return {} unless disable_thinking && provider == 'custom'

      { 'chat_template_kwargs' => { 'enable_thinking' => false } }
    end

    # --- Embeddings (for the knowledge base / RAG) --------------------------
    # Anthropic has no embeddings API; hence its own provider (openai/custom).
    # Key/endpoint fall back to the chat configuration when the same provider is
    # used and kb_embed_* is blank.
    EMBED_PROVIDERS     = %w[openai custom].freeze
    DEFAULT_EMBED_MODEL = 'text-embedding-3-small'.freeze

    def embed_provider
      p = @settings['kb_embed_provider'].to_s.strip
      EMBED_PROVIDERS.include?(p) ? p : 'openai'
    end

    def embed_model
      @settings['kb_embed_model'].to_s.strip.presence || DEFAULT_EMBED_MODEL
    end

    def embed_api_key
      key = @settings['kb_embed_api_key'].to_s.strip
      return key if key.present?

      embed_provider == provider ? api_key : ''
    end

    def embed_endpoint
      ep = @settings['kb_embed_endpoint'].to_s.strip
      return ep.chomp('/') if ep.present?

      base = embed_provider == provider ? endpoint : DEFAULT_ENDPOINTS[embed_provider].to_s
      base.to_s.chomp('/')
    end

    def embed_configured?
      embed_api_key.present? && embed_model.present? && embed_endpoint.present?
    end

    # Returns the embedding vector (Array<Float>) for text or raises AiError.
    #   log_context : optional { :request_type, :project_id, :issue_id } - as in summarize.
    def embed(text, log_context: nil)
      raise ConfigurationError, 'Embeddings are not configured (key/model/endpoint missing)' unless embed_configured?

      with_request_log(log_context, :provider => embed_provider, :model => embed_model, :default_type => 'kb_embed') do
        body = post_json("#{embed_endpoint}/embeddings",
                         { 'model' => embed_model, 'input' => text.to_s },
                         { 'Authorization' => "Bearer #{embed_api_key}" })
        vec = body.dig('data', 0, 'embedding')
        raise AiError.new('Empty embedding response from provider', nil, body.to_s) if vec.blank?

        # Record embedding usage (previously discarded): input tokens only.
        usage = body['usage'] || {}
        @last_usage = { :input => usage['prompt_tokens'] || usage['total_tokens'], :output => nil }
        vec
      end
    end

    # --- Reranking (cross-encoder, for the knowledge base / RAG) ----------
    # Second retrieval stage: the vector search is a bi-encoder and ranks on
    # whole-text proximity, so a ticket that merely shares vocabulary with the
    # query can outrank the one describing the same fault. A cross-encoder
    # scores query/document *pairs* and is far more precise - too expensive for
    # a whole collection, which is why it only ever sees a shortlist.
    #
    # Same provider as the embeddings (bge-m3 and bge-reranker-v2-m3 sit on one
    # base URL), so endpoint and key fall back to the kb_embed_* configuration
    # and a working knowledge base needs nothing but the toggle.
    DEFAULT_RERANK_MODEL   = 'bge-reranker-v2-m3'.freeze
    DEFAULT_RERANK_TIMEOUT = 10

    def rerank_enabled?
      @settings['kb_rerank_enabled'].to_s == '1'
    end

    # Every reader falls back to a default in code, not only through init.rb's
    # :default hash: a key added there reads nil on an existing installation
    # until the settings form has been saved once more.
    def rerank_model
      @settings['kb_rerank_model'].to_s.strip.presence || DEFAULT_RERANK_MODEL
    end

    def rerank_endpoint
      ep = @settings['kb_rerank_endpoint'].to_s.strip
      return ep.chomp('/') if ep.present?

      embed_endpoint
    end

    def rerank_api_key
      key = @settings['kb_rerank_api_key'].to_s.strip
      return key if key.present?

      embed_api_key
    end

    def rerank_timeout
      v = @settings['kb_rerank_timeout'].to_i
      v.positive? ? v : DEFAULT_RERANK_TIMEOUT
    end

    def rerank_configured?
      rerank_enabled? && rerank_api_key.present? && rerank_model.present? && rerank_endpoint.present?
    end

    # Scores documents (Array<String>) against query and returns
    #   [{ :index => Integer, :score => Float }, ...]
    # sorted descending, or raises AiError. :index points back into the
    # documents array that was passed in.
    #   log_context : optional { :project_id, :issue_id, ... } - as for embed.
    def rerank(query, documents, log_context: nil)
      raise ConfigurationError, 'Reranking is not configured (key/model/endpoint missing)' unless rerank_configured?

      docs = Array(documents).map(&:to_s)
      return [] if docs.empty?

      with_request_log(log_context, :provider => embed_provider, :model => rerank_model, :default_type => 'kb_rerank') do
        body = post_json("#{rerank_endpoint}/rerank",
                         { 'model' => rerank_model, 'query' => query.to_s, 'documents' => docs },
                         { 'Authorization' => "Bearer #{rerank_api_key}" },
                         :read_timeout => rerank_timeout)
        rows = parse_rerank_rows(body, docs.size)
        raise AiError.new('Empty rerank response from provider', nil, body.to_s) if rows.empty?

        usage = (body.is_a?(Hash) ? body['usage'] : nil) || {}
        @last_usage = { :input => usage['total_tokens'] || usage['prompt_tokens'], :output => nil }
        rows.sort_by { |r| -r[:score] }
      end
    end

    private

    # The provider documents the request only. Both common response shapes are
    # read, so swapping the runtime behind the same URL cannot silently shift
    # the scoring:
    #   Jina/Cohere (vLLM, Infinity):  { "results": [{ "index", "relevance_score" }] }
    #   TEI native:                    [{ "index", "score" }]
    def parse_rerank_rows(body, doc_count)
      raw = body.is_a?(Array) ? body : Array(body.is_a?(Hash) ? body['results'] : nil)
      rows = raw.filter_map do |r|
        next unless r.is_a?(Hash)

        idx = strict_int(r['index'])
        next if idx.nil? || idx.negative? || idx >= doc_count

        score = strict_float(r.key?('relevance_score') ? r['relevance_score'] : r['score'])
        next if score.nil?

        { :index => idx, :score => score }
      end
      normalize_rerank_scores(rows)
    end

    # The provider's numbers are not ours to trust. to_f reads "oops" as 0.0 and
    # "0.9garbage" as 0.9 - and kb_rerank_min_score = 0 is explicitly supported,
    # so an unscored document would be accepted as grounding. to_i is worse: it
    # reads "abc" as 0, which is not a rejected row but a confident pointer at
    # the first hit.
    #
    # A row that cannot be read is dropped rather than guessed at. If that leaves
    # nothing, rerank raises and retrieval keeps the vector order - the same
    # fallback as an unreachable reranker.
    def strict_float(value)
      v = case value
          when Numeric then value.to_f
          when String  then Float(value.strip)
          end
      v if v&.finite?
    rescue ArgumentError, TypeError
      nil
    end

    def strict_int(value)
      case value
      when Integer then value
      when Float   then value.finite? && value == value.truncate ? value.to_i : nil
      when String  then Integer(value.strip, 10)
      end
    rescue ArgumentError, TypeError
      nil
    end

    # bge-reranker-v2-m3 is a cross-encoder; its raw output is a logit. Some
    # runtimes squash it, others do not - the provider we measured
    # (api.ai.net.de) does NOT: one and the same query returned values from
    # +5.97 (identical text) down to -10.99 (entirely unrelated). Without the
    # normalisation kb_rerank_min_score would be silently inert there (every
    # value below 1 passes), and without any error, because the threshold is
    # calibrated on 0..1.
    #
    # The sigmoid is strictly monotonic, so the ranking never changes. It is
    # applied only when some value actually falls outside 0..1, so an already
    # normalised response passes through untouched.
    def normalize_rerank_scores(rows)
      return rows if rows.empty? || rows.all? { |r| r[:score] >= 0.0 && r[:score] <= 1.0 }

      rows.map { |r| r.merge(:score => 1.0 / (1.0 + Math.exp(-r[:score]))) }
    end

    # --- OpenAI / OpenAI-kompatibel (custom) -------------------------------
    def summarize_openai(system_prompt, user_text, image_parts, disable_thinking = false)
      content = user_text
      if image_parts.any?
        content = [{ 'type' => 'text', 'text' => user_text.to_s }]
        image_parts.each do |img|
          content << {
            'type'      => 'image_url',
            'image_url' => { 'url' => "data:#{img[:content_type]};base64,#{img[:data]}" }
          }
        end
      end

      # OpenAI (officially) requires 'max_completion_tokens' for GPT-5-/o-models and
      # rejects 'max_tokens' with HTTP 400; it also works for older models
      # (gpt-4o-mini ...). Self-hosted OpenAI-compatible servers (Ollama/vLLM/LocalAI)
      # on the other hand usually only understand 'max_tokens' -> stick with it for
      # the custom provider.
      token_param = provider == 'openai' ? 'max_completion_tokens' : 'max_tokens'
      payload = {
        'model'     => model,
        token_param => max_output_tokens,
        'messages'  => [
          { 'role' => 'system', 'content' => system_prompt.to_s },
          { 'role' => 'user',   'content' => content }
        ]
      }.merge(thinking_params(disable_thinking))

      body = post_json("#{endpoint.chomp('/')}/chat/completions", payload,
                       { 'Authorization' => "Bearer #{api_key}" })
      usage = body['usage'] || {}
      @last_usage = { :input => usage['prompt_tokens'], :output => usage['completion_tokens'] }
      @last_finish_reason = body.dig('choices', 0, 'finish_reason').to_s.presence
      text = body.dig('choices', 0, 'message', 'content').to_s.strip
      raise EmptyResponseError.new('Empty response from the AI provider', nil, body.to_s) if text.blank?

      text
    end

    # --- Anthropic Messages API --------------------------------------------
    def summarize_anthropic(system_prompt, user_text, image_parts)
      content = user_text
      if image_parts.any?
        content = [{ 'type' => 'text', 'text' => user_text.to_s }]
        image_parts.each do |img|
          content << {
            'type'   => 'image',
            'source' => { 'type' => 'base64', 'media_type' => img[:content_type], 'data' => img[:data] }
          }
        end
      end

      payload = {
        'model'      => model,
        'max_tokens' => max_output_tokens,
        'system'     => system_prompt.to_s,
        'messages'   => [{ 'role' => 'user', 'content' => content }]
      }

      body = post_json("#{endpoint.chomp('/')}/v1/messages", payload,
                       { 'x-api-key' => api_key, 'anthropic-version' => ANTHROPIC_VERSION })
      usage = body['usage'] || {}
      @last_usage = { :input => usage['input_tokens'], :output => usage['output_tokens'] }
      # Anthropic says 'max_tokens'; normalise to OpenAI's 'length' so callers
      # only ever compare against one vocabulary.
      raw_stop = body['stop_reason'].to_s
      @last_finish_reason = raw_stop == 'max_tokens' ? 'length' : raw_stop.presence
      text = Array(body['content']).map { |c| c['text'] }.compact.join.strip
      raise EmptyResponseError.new('Empty response from the AI provider', nil, body.to_s) if text.blank?

      text
    end

    # Network errors that Net::HTTP raises and that nobody has seen before the reply
    # draft: the jobs run in the background, where everything lands in the log. From
    # a web request, an unhandled exception would produce the HTML error page, and
    # the JSON client in the browser shows the operator "Unexpected token '<'".
    NETWORK_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, SocketError,
                      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
                      OpenSSL::SSL::SSLError].freeze

    # POST JSON, parse JSON, raise AiError on non-2xx. Analogous to GraphClient#request.
    # read_timeout: overrides this call's time budget (reranking has its own,
    # much tighter than a text generation).
    #
    # The connect phase is bounded by whatever budget applies, never by the fixed
    # 15 s alone: a blackholed host spends its time connecting, not reading, so a
    # call given 5 s could otherwise block for 20. Every synchronous caller sizes
    # something on these numbers - the answer draft sizes the lock that stops a
    # second paid draft starting while the first still runs - and a bound that
    # only covers the read phase is not a bound.
    #
    # extra_headers is passed as a hash literal at every call site - without the
    # braces Ruby 3 would read the trailing hash as keyword arguments, now that
    # this method has one.
    DEFAULT_OPEN_TIMEOUT = 15

    def post_json(url, payload, extra_headers = {}, read_timeout: nil)
      budget = read_timeout || self.read_timeout
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = [DEFAULT_OPEN_TIMEOUT, budget].min
      http.read_timeout = budget

      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req['Accept'] = 'application/json'
      extra_headers.each { |k, v| req[k] = v }
      req.body = payload.to_json

      response = http.request(req)
      unless response.is_a?(Net::HTTPSuccess)
        raise AiError.new("AI request failed (HTTP #{response.code})", response.code.to_i, response.body)
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise AiError.new("AI response not readable: #{e.message}")
    rescue *NETWORK_ERRORS => e
      raise TransportError.new("AI service unreachable: #{e.class}", nil, e.message)
    end

    # Runs the AI call and records it (success or failure) in HelpdeskAiRequest,
    # provided a log_context was passed. The block sets @last_usage; the tokens are
    # read out after a successful yield. Without a context (nil) the call is only
    # executed, not recorded (backwards compatible).
    def with_request_log(context, provider:, model:, default_type:)
      return yield if context.nil?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        result = yield
        log_ai_request(context, :provider => provider, :model => model, :default_type => default_type,
                       :duration_ms => elapsed_ms(started), :success => true,
                       :input => @last_usage[:input], :output => @last_usage[:output])
        result
      rescue AiError => e
        log_ai_request(context, :provider => provider, :model => model, :default_type => default_type,
                       :duration_ms => elapsed_ms(started), :success => false,
                       :error_class => e.class.name, :http_status => e.status)
        raise
      rescue => e
        log_ai_request(context, :provider => provider, :model => model, :default_type => default_type,
                       :duration_ms => elapsed_ms(started), :success => false, :error_class => e.class.name)
        raise
      end
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    # Writes a log line. Errors here must never break the AI flow.
    def log_ai_request(context, provider:, model:, default_type:, duration_ms:, success:,
                       input: nil, output: nil, error_class: nil, http_status: nil)
      HelpdeskAiRequest.create!(
        :request_type  => (context[:request_type].presence || default_type).to_s,
        :provider      => provider,
        :model         => model,
        :project_id    => context[:project_id],
        :issue_id      => context[:issue_id],
        # Only the answer draft sets this; the jobs run without an acting user.
        :user_id       => context[:user_id],
        :input_tokens  => input,
        :output_tokens => output,
        :duration_ms   => duration_ms,
        :success       => success,
        :error_class   => error_class,
        :http_status   => http_status
      )
    rescue => e
      Rails.logger.warn("[helpdesk][ai] Usage log could not be saved: #{e.class}: #{e.message}")
    end
  end
end

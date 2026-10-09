# Completeness check for the initial mail of a helpdesk ticket.
#
# Customers regularly open a ticket with "Drucker geht nicht" and nothing else.
# This class decides whether such a mail carries enough information for an agent
# to start working, so HelpdeskCompletenessJob can ask the customer for the rest
# before the SLA clock has burnt the first cycle.
#
# Subject and body are evaluated together: the subject line is often the only
# place a customer names the affected device, and asking for it again is exactly
# the kind of follow-up that annoys people.
#
# Two modes, both ending in the same Verdict:
# - heuristic: the rule set configured per project (length, attachments,
#   keywords). No external dependency, no cost, works with AI switched off.
# - ai: the model answers with JSON, parsed by parse_ai_verdict below.
#
# Reasons are returned as SYMBOLS, not sentences: the mail to the customer, the
# journal note and the tests each render them in their own locale. AI reasons are
# free text from the model and are passed through as strings.
#
# This class is pure (no DB writes, no mail, no HTTP) so the rule table is
# testable without a Redmine environment.
require 'json'

module RedmineExpertHelpdesk
  class CompletenessCheck
    # complete : true when the mail is good enough (no request is sent)
    # reasons  : symbols (heuristic) or strings (ai) naming what is missing
    # source   : 'heuristic' | 'ai' | 'error' — 'error' always means "complete",
    #            see the fail-closed rule in parse_ai_verdict.
    Verdict = Struct.new(:complete, :reasons, :source, :keyword_init => true) do
      def complete?
        complete ? true : false
      end

      def incomplete?
        !complete?
      end
    end

    MODES = %w[off heuristic ai].freeze

    # Images below this size do not count as a screenshot/photo. Signature logos and
    # tracking pixels are attached to nearly every mail and are typically 1-10 KB;
    # a real screenshot or a phone photo is well above that.
    DEFAULT_MIN_ATTACHMENT_KB = 15

    # Quoted history and signatures are not new information, so they must not
    # push a two-word mail over the length threshold. Covers Outlook (German and
    # English), Gmail/Thunderbird ("Am ... schrieb ...:"), plain "> " quoting and
    # the RFC 3676 signature delimiter.
    QUOTE_MARKERS = [
      /^\s*-{2,}\s*(urspr(ü|ue)ngliche nachricht|original message|weitergeleitete nachricht|forwarded message)\s*-{2,}/i,
      /^\s*_{5,}\s*$/,
      /^\s*-- \s*$/,
      /^\s*(von|from|gesendet|sent|betreff|subject|an|to)\s*:\s.*$\n^\s*(von|from|gesendet|sent|betreff|subject|an|to)\s*:\s/i,
      /^\s*(am|on)\s.{0,80}\s(schrieb|wrote)\s*:?\s*$/i
    ].freeze

    # Central default prompt for the AI mode. Deliberately asks for STRICT JSON and
    # for a conservative verdict: a false "incomplete" mails a customer who did
    # nothing wrong, which is worse than a missed check. The prompt text itself is
    # Russian on purpose - it is user-facing content shown in the settings form.
    DEFAULT_AI_PROMPT = <<~PROMPT.freeze
      Ты — ассистент в технической поддержке (Helpdesk). Проверь, содержит ли
      следующее сообщение клиента достаточно информации, чтобы сотрудник мог
      начать обработку.

      Сообщение, как правило, достаточно, когда видно:
      - о чем идет речь (затронутая система, приложение, устройство или сервис),
      - что именно происходит (текст ошибки, симптом, наблюдаемое поведение),
      - с каких пор или когда это проявляется или как это можно воспроизвести.

      Сообщение начинается со строки темы («Тема: ...»). Данные из темы так же
      важны, как и данные из текста — не спрашивай того, что там уже есть.

      Изображения почти всегда помогают, поэтому дополнительно:
      - Если речь о ПРОГРАММНОМ ОБЕСПЕЧЕНИИ (приложение, веб-портал, операционная
        система, диалог ошибки, сообщение на экране)? Тогда должен быть
        СКРИНШОТ текста ошибки или соответствующего окна.
      - Если речь об ОБОРУДОВАНИИ (устройство, принтер, касса, экран, кабель,
        блок питания, повреждение, индикация на устройстве)? Тогда должно быть
        ФОТО устройства или нужного места — по возможности с шильдиком,
        серийным номером или индикацией на дисплее.
      - Если нельзя определить, программное это обеспечение или оборудование,
        не требуй изображений, а спроси о затронутой системе.

      В конце сообщения находится раздел «Вложения этого письма:» с
      прикрепленными файлами. НИКОГДА не требуй того, что там уже указано:
      если изображение приложено, требование изображения выполнено. Если там
      написано «нет», в письме нет пригодных вложений. Крошечные изображения
      (логотипы подписей, пиксели отслеживания) уже отфильтрованы и там не
      появляются — тебе не нужно распознавать их самому.

      При сомнении оценивай как достаточное. Лишний уточняющий запрос раздражает
      клиентов, написавших все необходимое. Чистая вежливость, подписи и
      цитируемые переписки информацией не считаются.

      Отвечай ИСКЛЮЧИТЕЛЬНО JSON в точно такой форме, без блока кода и без
      дополнительного текста:
      {"complete": true|false, "missing": ["недостающее сведение 1", "недостающее сведение 2"]}

      При "complete": true поле "missing" должно быть пустым массивом. Формулируй
      записи в "missing" как короткие вежливые пункты на русском языке, которые
      можно сразу предъявить клиенту в качестве уточняющего запроса.
    PROMPT

    class << self
      # setting: a HelpdeskProjectSetting (or any object answering the same
      # info_request_* readers — the tests pass a Struct).
      # subject: the mail subject, measured together with the body. It is joined
      # after meaningful_text so the quote/forward stripping never touches it - a
      # subject "Betreff: Drucker" must not be mistaken for a forwarded header.
      def evaluate(text:, subject: nil, attachments: [], setting:)
        body = [subject.to_s.strip, meaningful_text(text)].reject(&:blank?).join(' ')
        reasons = []

        min_chars = setting.info_request_min_chars.to_i
        reasons << :too_short if min_chars.positive? && body.length < min_chars

        min_words = setting.info_request_min_words.to_i
        reasons << :too_few_words if min_words.positive? && word_count(body) < min_words

        if setting.info_request_require_attachment? &&
           relevant_attachments(attachments, setting).empty?
          reasons << :no_attachment
        end

        keywords = keyword_list(setting)
        if keywords.any? && keywords.none? { |k| body.downcase.include?(k) }
          reasons << :no_keyword
        end

        # A threshold of 0 or below would fire on a perfect mail, so treat it as 1.
        threshold = setting.info_request_threshold.to_i
        threshold = 1 unless threshold.positive?

        Verdict.new(
          :complete => reasons.size < threshold,
          :reasons => reasons,
          :source => 'heuristic'
        )
      end

      # Parses the model's answer. FAILS CLOSED: anything we cannot read counts as
      # complete, because a garbled response must never trigger a mail to a customer.
      def parse_ai_verdict(raw)
        json = extract_json(raw.to_s)
        return error_verdict('no JSON answer received') if json.nil?

        data = JSON.parse(json)
        return error_verdict('unexpected JSON structure') unless data.is_a?(Hash)

        complete = data['complete']
        # Only a literal false (or "false") counts as incomplete; a missing or
        # non-boolean key is a malformed answer, not a verdict.
        return error_verdict('field "complete" missing or not a boolean') unless
          [true, false, 'true', 'false'].include?(complete)

        return Verdict.new(:complete => true, :reasons => [], :source => 'ai') if
          complete == true || complete == 'true'

        missing = Array(data['missing']).map { |m| m.to_s.strip }.reject(&:blank?)
        # "incomplete" without a single reason gives the customer nothing to answer.
        return error_verdict('incomplete without reason') if missing.empty?

        Verdict.new(:complete => false, :reasons => missing, :source => 'ai')
      rescue JSON::ParserError => e
        error_verdict("JSON not readable: #{e.message}")
      end

      # Strips quoted history and normalises whitespace, so quoted-printable line
      # noise and a forwarded thread cannot inflate the measured length.
      def meaningful_text(text)
        body = text.to_s
        QUOTE_MARKERS.each do |marker|
          if (match = body.match(marker))
            body = body[0...match.begin(0)]
          end
        end
        body = body.lines.reject { |line| line =~ /^\s*>/ }.join
        body.gsub(/\s+/, ' ').strip
      end

      # Attachments that count as evidence. The size floor applies to IMAGES ONLY:
      # it exists because of signature logos and tracking pixels, which would
      # otherwise make every mail look like it came "with a screenshot". A 2 KB log
      # or a small PDF is evidence of a different kind and stays.
      def relevant_attachments(attachments, setting = nil)
        min_bytes = min_attachment_kb(setting) * 1024

        Array(attachments).reject do |a|
          next false unless image?(a)
          next false unless min_bytes.positive?

          size = a.respond_to?(:filesize) ? a.filesize.to_i : 0
          # Unknown size (0/nil) => keep it when in doubt, never discard.
          size.positive? && size < min_bytes
        end
      end

      def min_attachment_kb(setting)
        return DEFAULT_MIN_ATTACHMENT_KB unless
          setting.respond_to?(:info_request_min_attachment_kb)

        value = setting.info_request_min_attachment_kb
        # nil => default; 0 deliberately switches the floor off.
        value.nil? ? DEFAULT_MIN_ATTACHMENT_KB : value.to_i
      end

      # One definition for both features - ImageRelevance applies the same test
      # before handing images to the vision model.
      def image?(attachment)
        ImageRelevance.image?(attachment)
      end

      # Attachment inventory for the AI mode. The prompt asks for screenshots/photos
      # but, without this list, cannot see that one is already attached - it would
      # then demand something the customer has already sent.
      # Name + type are enough; the image data itself is deliberately NOT included.
      def attachment_inventory(attachments, setting = nil)
        list = relevant_attachments(attachments, setting).filter_map do |a|
          name = a.respond_to?(:filename) ? a.filename.to_s : a.to_s
          next if name.blank?

          type = a.respond_to?(:content_type) ? a.content_type.to_s : ''
          type.present? ? "#{name} (#{type})" : name
        end

        "\n\nВложения этого письма: #{list.any? ? list.join(', ') : 'нет'}"
      end

      # Model input for the AI mode, in a fixed order: subject line first, then the
      # body cut to max_chars, then the attachment inventory. Subject and inventory
      # are added AFTER truncating, so a long forwarded thread can cut off neither.
      def ai_input(text:, subject: nil, attachments: [], setting: nil, max_chars: nil)
        body = text.to_s
        limit = max_chars.to_i
        body = body.first(limit) if limit.positive?

        head = subject.to_s.strip
        head = head.present? ? "Тема: #{head}\n\n" : ''

        head + body + attachment_inventory(attachments, setting)
      end

      def keyword_list(setting)
        setting.info_request_keywords.to_s
               .split(/[\r\n,]+/)
               .map { |k| k.strip.downcase }
               .reject(&:empty?)
      end

      private

      def word_count(body)
        body.split(/\s+/).count { |w| w =~ /[[:alnum:]]/ }
      end

      # Models like to wrap JSON in ```json fences or to prefix a sentence.
      # Take the outermost braces and let JSON.parse judge the rest.
      def extract_json(raw)
        first = raw.index('{')
        last  = raw.rindex('}')
        return nil if first.nil? || last.nil? || last < first

        raw[first..last]
      end

      def error_verdict(message)
        Rails.logger.warn("[helpdesk][info_request] AI answer discarded: #{message}")
        Verdict.new(:complete => true, :reasons => [], :source => 'error')
      rescue StandardError
        Verdict.new(:complete => true, :reasons => [], :source => 'error')
      end
    end
  end
end

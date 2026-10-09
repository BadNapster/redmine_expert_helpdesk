# Checks incoming mails for known phishing URLs (local feed mirror)
# and neutralizes hits in the MIME body.
#
# Additional heuristics for obfuscated links (warning box instead of removal):
#   - Redirect links: the URL carries a second, url-encoded target URL in the
#     query parameter (e.g. redirect-url.email/?link=https%3A%2F%2F...)
#   - Short URL services (bit.ly, tinyurl, ...): target not recognizable
#   - Anchor mismatch: visible link text shows a different domain than the href target
#
# Microsoft SafeLinks (*.safelinks.protection.outlook.com) are decoded
# locally (the original URL is url-encoded in the query parameter "url") -
# no HTTP request takes place.
#
# Return value of scan: { :mime =>, :hits => [...], :suspicions => [...] }
# Hit:      { :url, :resolved_url, :phish_id, :target, :source_label }
# Suspicion: { :url, :reason (:redirect|:shortener|:anchor_mismatch), :detail, :label }

require 'cgi'

module RedmineExpertHelpdesk
  class PhishingScanner
    # Rough URL detection in plain text; final check happens normalized.
    URL_PATTERN = %r{https?://[^\s<>"'\)\]]+}i.freeze

    SAFELINKS_HOST_SUFFIX = '.safelinks.protection.outlook.com'.freeze

    # Known short URL/redirect services (target not recognizable)
    SHORTENER_DOMAINS = %w[
      bit.ly tinyurl.com t.co goo.gl is.gd ow.ly buff.ly cutt.ly rebrand.ly
      tiny.cc rb.gy shorturl.at s.id t.ly v.gd qr.ae adf.ly rotf.lol lnkiy.com
    ].freeze

    # HTML anchor with absolute target and visible text
    ANCHOR_PATTERN = %r{<a\b[^>]*href\s*=\s*["']?(https?://[^"'\s>]+)["']?[^>]*>(.*?)</a>}im.freeze

    # Domain-like token in the visible link text (e.g. "www.paypal.com")
    DOMAIN_IN_TEXT = %r{(?:[a-z0-9][a-z0-9-]*\.)+[a-z]{2,}}i.freeze

    def self.scan(mime)
      new.scan(mime)
    end

    def scan(mime)
      mail = Mail.read_from_string(mime)
      hits = {}
      suspicions = {}
      urls_checked = 0

      parts = scannable_parts(mail)
      Rails.logger.info "Helpdesk/Phishing: Scanning #{parts.size} mail part(s) (#{parts.map { |p| p.content_type.to_s.split(';').first }.join(', ')})"

      parts.each do |part|
        body = decoded_body(part)
        if body.blank?
          Rails.logger.debug "Helpdesk/Phishing: Part #{part.content_type.to_s.split(';').first} has no decodable body"
          next
        end

        is_html = part.content_type.to_s =~ %r{text/html}i
        urls = extract_urls(body)
        Rails.logger.info "Helpdesk/Phishing: #{urls.size} URL(s) found in #{part.content_type.to_s.split(';').first}"

        urls.each do |url|
          next if hits.key?(url) || suspicions.key?(url)

          urls_checked += 1
          resolved = resolve_safelink(url)
          if resolved != url
            Rails.logger.info "Helpdesk/Phishing: SafeLink resolved: #{url.truncate(120)} -> #{resolved.truncate(120)}"
          end

          embedded = extract_embedded_url(resolved)

          entry = HelpdeskPhishingUrl.lookup(resolved) || HelpdeskPhishingUrl.lookup(url) ||
                  (embedded && HelpdeskPhishingUrl.lookup(embedded))
          if entry
            source_label = entry.source == 'phishing_database' ? 'Phishing.Database' : "PhishTank ##{entry.phish_id}"
            Rails.logger.warn "Helpdesk/Phishing: HIT for #{resolved.truncate(200)} (#{source_label})"
            hits[url] = {
              :url          => url,
              :resolved_url => resolved == url ? nil : resolved,
              :phish_id     => entry.phish_id,
              :target       => entry.target,
              :source_label => source_label
            }
          elsif embedded
            Rails.logger.warn "Helpdesk/Phishing: SUSPICION (redirect) #{url.truncate(120)} -> #{embedded.truncate(120)}"
            suspicions[url] = build_suspicion(url, :redirect, embedded)
          elsif shortener?(resolved)
            Rails.logger.warn "Helpdesk/Phishing: SUSPICION (short URL) #{resolved.truncate(120)}"
            suspicions[url] = build_suspicion(url, :shortener, nil)
          else
            Rails.logger.debug "Helpdesk/Phishing: no hit for #{resolved.truncate(200)} (Hash: #{HelpdeskPhishingUrl.hash_for(resolved)})"
          end
        end

        # Anchor mismatch: visible link text shows a different domain than the target
        next unless is_html

        find_anchor_mismatches(body).each do |m|
          next if hits.key?(m[:href]) || suspicions.key?(m[:href])

          Rails.logger.warn "Helpdesk/Phishing: SUSPICION (link text mismatch) text shows #{m[:shown]}, target is #{m[:actual]}"
          suspicions[m[:href]] = build_suspicion(m[:href], :anchor_mismatch, "#{m[:shown]} -> #{m[:actual]}")
        end
      end

      Rails.logger.info "Helpdesk/Phishing: Scan finished – #{urls_checked} URL(s) checked, #{hits.size} hits, #{suspicions.size} suspicions"

      return { :mime => mime, :hits => [], :suspicions => [] } if hits.empty? && suspicions.empty?

      parts.each do |part|
        rewrite_part(part, hits, suspicions)
      end

      { :mime => mail.to_s, :hits => hits.values, :suspicions => suspicions.values }
    rescue StandardError => e
      Rails.logger.error "Helpdesk: Phishing scan failed: #{e.message}"
      { :mime => mime, :hits => [], :suspicions => [] }
    end

    # Decodes a SafeLinks URL to the original URL. Non-SafeLinks URLs
    # are returned unchanged.
    def resolve_safelink(url)
      uri = URI.parse(url)
      return url unless uri.host&.downcase&.end_with?(SAFELINKS_HOST_SUFFIX)

      original = query_pairs(uri).find { |key, _value| key == 'url' }&.last
      original.presence || url
    rescue URI::Error
      url
    end

    private

    # Returns the mail parts to scan (text/plain + text/html).
    # For non-multipart mails the mail itself.
    def scannable_parts(mail)
      if mail.multipart?
        mail.all_parts.select do |p|
          p.content_type.to_s =~ %r{text/(plain|html)}i && !p.attachment?
        end
      else
        [mail]
      end
    end

    # Decodes the part body to UTF-8 respecting the declared
    # charsets (Outlook often sends windows-1252/iso-8859-1). Invalid bytes
    # are replaced (scrub) so the regex scan does not fail with
    # "invalid byte sequence in UTF-8".
    def decoded_body(part)
      body = part.body.decoded.dup
      charset = part.charset.to_s.presence

      if charset && charset.downcase !~ /utf-?8/
        begin
          body.force_encoding(charset)
          body = body.encode('UTF-8', :invalid => :replace, :undef => :replace, :replace => ' ')
        rescue StandardError
          body.force_encoding('UTF-8')
        end
      else
        body.force_encoding('UTF-8')
      end

      body.scrub(' ')
    rescue StandardError
      nil
    end

    def extract_urls(body)
      body.scan(URL_PATTERN).map { |u| u.sub(/[.,;:!?]+\z/, '') }.uniq
    end

    # Extracts an absolute target URL embedded in the query parameter
    # (redirect/tracking links like ...?link=https%3A%2F%2Fevil.example%2F).
    # query_pairs already decodes the values. Returns nil when none is present.
    def extract_embedded_url(url)
      uri = URI.parse(url)
      return nil if uri.query.blank?

      query_pairs(uri).each do |_key, value|
        candidate = value.to_s.strip
        return candidate if candidate =~ %r{\Ahttps?://}i
      end
      nil
    rescue StandardError
      nil
    end

    # Query string as [[key, value], ...] with decoded values.
    #
    # Replaces CGI.parse, which Ruby 4.0 removed. Not
    # URI.decode_www_form either: that raises on a segment without "=" and then
    # discards the whole query string including its valid pairs. CGI.parse was
    # tolerant here, and that is exactly what matters - the
    # redirect links we want to unpack are rarely cleanly built.
    def query_pairs(uri)
      return [] if uri.query.blank?

      uri.query.split(/[&;]/).filter_map do |pair|
        key, value = pair.split('=', 2)
        next if key.nil? || key.empty?

        [decode_component(key), decode_component(value)]
      end
    end

    def decode_component(value)
      URI.decode_www_form_component(value.to_s)
    rescue ArgumentError
      # Broken percent encoding: pass through unchanged instead of losing the
      # whole link.
      value.to_s
    end

    # Is the host a known short URL service?
    def shortener?(url)
      host = URI.parse(url).host.to_s.downcase.sub(/\Awww\./, '')
      return false if host.empty?

      SHORTENER_DOMAINS.any? { |d| host == d || host.end_with?(".#{d}") }
    rescue URI::Error
      false
    end

    # Finds HTML anchors whose visible text shows a different domain
    # than the href target (classic link obfuscation).
    def find_anchor_mismatches(html)
      html.scan(ANCHOR_PATTERN).filter_map do |href, inner|
        shown = inner.gsub(/<[^>]+>/, ' ')[DOMAIN_IN_TEXT]
        next unless shown

        href_host = begin
          URI.parse(href).host.to_s.downcase.sub(/\Awww\./, '')
        rescue URI::Error
          nil
        end
        next if href_host.blank?

        shown_host = shown.downcase.sub(/\Awww\./, '').chomp('.')
        next if href_host == shown_host ||
                href_host.end_with?(".#{shown_host}") ||
                shown_host.end_with?(".#{href_host}")

        { :href => href.sub(/[.,;:!?]+\z/, ''), :shown => shown_host, :actual => href_host }
      end
    end

    def build_suspicion(url, reason, detail)
      label = case reason
              when :redirect
                I18n.t(:text_helpdesk_phishing_suspicion_redirect, :target => detail)
              when :shortener
                I18n.t(:text_helpdesk_phishing_suspicion_shortener)
              else
                I18n.t(:text_helpdesk_phishing_suspicion_anchor, :detail => detail)
              end
      { :url => url, :reason => reason, :detail => detail, :label => label }
    end

    # Replaces hit URLs, marks suspicions with a warning box and prepends
    # a warning banner.
    def rewrite_part(part, hits, suspicions)
      body = decoded_body(part)
      return if body.blank?

      changed = false
      is_html = part.content_type.to_s =~ %r{text/html}i

      hits.each_value do |hit|
        replacement = replacement_text(hit, is_html)
        escaped_url = Regexp.escape(hit[:url])
        next unless body =~ /#{escaped_url}/

        body = body.gsub(/#{escaped_url}/, replacement)
        changed = true
      end

      suspicions.each_value do |suspicion|
        escaped_url = Regexp.escape(suspicion[:url])
        if is_html
          # Warning box behind the associated anchor (never write into attributes)
          anchor = /(<a\b[^>]*href\s*=\s*["']?#{escaped_url}["']?[^>]*>.*?<\/a>)/im
          if body =~ anchor
            box = suspicion_html_box(suspicion[:label])
            body = body.gsub(anchor) { "#{Regexp.last_match(1)}#{box}" }
            changed = true
          end
        elsif body =~ /#{escaped_url}/
          body = body.gsub(/#{escaped_url}/) { |u| "#{u} [⚠ #{suspicion[:label]}]" }
          changed = true
        end
      end

      return unless changed

      banner = if hits.any?
                 is_html ? html_banner : text_banner
               else
                 is_html ? html_suspicion_banner : text_suspicion_banner
               end
      body = banner + body

      # Body is now UTF-8 - set the part's charset accordingly,
      # otherwise the recipient interprets the bytes in the old charset.
      part.body = nil
      part.charset = 'UTF-8'
      part.content_transfer_encoding = 'base64'
      part.body = Mail::Encodings::Base64.encode(body)
    end

    def replacement_text(hit, is_html)
      label = I18n.t(:text_helpdesk_phishing_link_removed, :source => hit[:source_label])
      is_html ? "<span style=\"color:#c00; font-weight:bold;\">[#{label}]</span>" : "[#{label}]"
    end

    def text_banner
      "!!! #{I18n.t(:text_helpdesk_phishing_warning_banner)} !!!\n\n"
    end

    def html_banner
      "<div style=\"background:#c00; color:#fff; padding:8px; font-weight:bold; margin-bottom:10px;\">" \
        "&#9888; #{I18n.t(:text_helpdesk_phishing_warning_banner)}</div>"
    end

    def text_suspicion_banner
      "!!! #{I18n.t(:text_helpdesk_phishing_suspicion_banner)} !!!\n\n"
    end

    def html_suspicion_banner
      "<div style=\"background:#fff3cd; color:#7a5c00; border:2px solid #e0a800; padding:8px; font-weight:bold; margin-bottom:10px;\">" \
        "&#9888; #{I18n.t(:text_helpdesk_phishing_suspicion_banner)}</div>"
    end

    def suspicion_html_box(label)
      "<span style=\"display:inline-block; background:#fff3cd; color:#7a5c00; border:1px solid #e0a800; " \
        "padding:2px 6px; margin:0 4px; font-weight:bold;\">&#9888; #{ERB::Util.html_escape(label)}</span>"
    end
  end
end

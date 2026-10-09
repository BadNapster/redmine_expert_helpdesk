# Downloads the PhishTank database (online-valid.json.gz) and
# mirrors it into the helpdesk_phishing_urls table (source: 'phishtank').
#
# Without an app key the anonymous endpoint is used (stricter rate limit,
# do not choose an interval below 1 hour). PhishTank requires a
# meaningful user agent in the format "phishtank/<name>".
#
# Orchestration (interval, lock, multiple feeds): PhishingFeeds.

require 'net/http'
require 'uri'
require 'json'
require 'zlib'
require 'stringio'

module RedmineExpertHelpdesk
  class PhishtankSync
    # Preset feed URL; {key} is replaced by the app key (if present).
    # Without a key the "/{key}" path segment is removed completely (anonymous endpoint).
    DEFAULT_FEED_URL = 'https://data.phishtank.com/data/{key}/online-valid.json.gz'.freeze
    USER_AGENT = 'phishtank/redmine-expert-helpdesk'.freeze
    SOURCE     = 'phishtank'.freeze

    class SyncError < StandardError; end

    def initialize(app_key = nil, feed_url_template = nil)
      @app_key = app_key.to_s.strip
      @feed_url_template = feed_url_template.to_s.strip
    end

    # Download + full import of the source 'phishtank' in one transaction.
    # On errors the old data remains unchanged.
    def run
      entries = fetch_entries
      raise SyncError, 'PhishTank feed is empty' if entries.empty?

      rows = build_rows(entries, Time.current)
      count = HelpdeskPhishingUrl.replace_source!(SOURCE, rows)

      Rails.logger.info "Helpdesk: PhishTank sync finished – #{count} URLs imported"
      count
    rescue SyncError, StandardError => e
      Rails.logger.error "Helpdesk: PhishTank sync failed: #{e.message}"
      raise SyncError, e.message
    end

    private

    # Builds the effective feed URL from the configured template:
    # - {key} is replaced by the app key
    # - without an app key the "/{key}" path segment is removed (anonymous endpoint)
    def feed_url
      template = @feed_url_template.presence || DEFAULT_FEED_URL
      if @app_key.present?
        template.gsub('{key}', @app_key)
      else
        template.gsub('/{key}', '').gsub('{key}', '')
      end
    end

    def fetch_entries(redirect_limit = 3)
      raise SyncError, 'Too many redirects while downloading from PhishTank' if redirect_limit.zero?

      uri = URI.parse(@redirect_url || feed_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = (uri.scheme == 'https')
      http.open_timeout = 15
      http.read_timeout = 120

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT

      response = http.request(request)

      case response
      when Net::HTTPSuccess
        parse_gzip_json(response.body)
      when Net::HTTPRedirection
        @redirect_url = response['location']
        fetch_entries(redirect_limit - 1)
      when Net::HTTPTooManyRequests
        raise SyncError, 'PhishTank rate limit reached (HTTP 429) – increase the interval'
      else
        raise SyncError, "PhishTank download failed (HTTP #{response.code})"
      end
    end

    def parse_gzip_json(body)
      json = Zlib::GzipReader.new(StringIO.new(body)).read
      JSON.parse(json)
    rescue Zlib::GzipFile::Error
      # Feed arrived uncompressed (content negotiation) – parse directly
      JSON.parse(body)
    rescue JSON::ParserError => e
      raise SyncError, "PhishTank feed unreadable: #{e.message}"
    end

    # Builds insert_all rows; duplicates (same hash) are skipped.
    def build_rows(entries, now)
      seen = {}
      entries.each_with_object([]) do |entry, rows|
        url = entry['url'].to_s
        next if url.empty?

        hash = HelpdeskPhishingUrl.hash_for(url)
        next if seen[hash]

        seen[hash] = true
        rows << {
          :url         => url,
          :url_hash    => hash,
          :phish_id    => entry['phish_id'].to_i,
          :target      => entry['target'].to_s.presence,
          :source      => SOURCE,
          :imported_at => now
        }
      end
    end
  end
end

# Downloads the Phishing.Database feed (github.com/Phishing-Database/Phishing.Database)
# and mirrors it into the helpdesk_phishing_urls table
# (source: 'phishing_database').
#
# The feed is a plain text list (one URL per line, active phishing links,
# validated by PyFunceble). No API key required.
#
# Orchestration (interval, lock, multiple feeds): PhishingFeeds.

require 'net/http'
require 'uri'
require 'zlib'
require 'stringio'

module RedmineExpertHelpdesk
  class PhishingDatabaseSync
    DEFAULT_FEED_URL = 'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-links-ACTIVE.txt'.freeze
    USER_AGENT = 'redmine-expert-helpdesk'.freeze
    SOURCE     = 'phishing_database'.freeze

    class SyncError < StandardError; end

    def initialize(feed_url = nil)
      @feed_url = feed_url.to_s.strip
    end

    # Download + full import of the source 'phishing_database' in one transaction.
    # On errors the old data remains unchanged.
    def run
      body = fetch_body
      rows = build_rows(body, Time.current)
      raise SyncError, 'Phishing.Database feed is empty' if rows.empty?

      count = HelpdeskPhishingUrl.replace_source!(SOURCE, rows)

      Rails.logger.info "Helpdesk: Phishing.Database sync finished – #{count} URLs imported"
      count
    rescue SyncError, StandardError => e
      Rails.logger.error "Helpdesk: Phishing.Database sync failed: #{e.message}"
      raise SyncError, e.message
    end

    private

    def feed_url
      @feed_url.presence || DEFAULT_FEED_URL
    end

    def fetch_body(redirect_limit = 3)
      raise SyncError, 'Too many redirects while downloading from Phishing.Database' if redirect_limit.zero?

      uri = URI.parse(@redirect_url || feed_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = (uri.scheme == 'https')
      http.open_timeout = 15
      http.read_timeout = 180

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT

      response = http.request(request)

      case response
      when Net::HTTPSuccess
        decompress(response)
      when Net::HTTPRedirection
        @redirect_url = response['location']
        fetch_body(redirect_limit - 1)
      when Net::HTTPTooManyRequests
        raise SyncError, 'Phishing.Database rate limit reached (HTTP 429) – increase the interval'
      else
        raise SyncError, "Phishing.Database download failed (HTTP #{response.code})"
      end
    end

    # Decompress the response if needed (GitHub delivers gzip-compressed depending on header).
    def decompress(response)
      body = response.body.to_s
      if response['content-encoding'].to_s.include?('gzip') || body.start_with?("\x1f\x8b".b)
        Zlib::GzipReader.new(StringIO.new(body)).read
      else
        body
      end
    end

    # One URL per line; skip blank lines and comments,
    # interpret lines without a scheme as http:// (domain lists).
    def build_rows(body, now)
      seen = {}
      # dup before force_encoding: the body may be frozen (e.g. in tests),
      # and we do not want to modify the caller's input in place anyway.
      normalized = body.to_s.dup.force_encoding('UTF-8').scrub(' ')
      normalized.split(/\r?\n/).each_with_object([]) do |line, rows|
        url = line.strip
        next if url.empty? || url.start_with?('#')

        url = "http://#{url}" unless url =~ %r{\Ahttps?://}i

        hash = HelpdeskPhishingUrl.hash_for(url)
        next if seen[hash]

        seen[hash] = true
        rows << {
          :url         => url,
          :url_hash    => hash,
          :phish_id    => nil,
          :target      => nil,
          :source      => SOURCE,
          :imported_at => now
        }
      end
    end
  end
end

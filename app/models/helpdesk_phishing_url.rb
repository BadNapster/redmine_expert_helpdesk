# Local mirror of the PhishTank database.
# One row per known phishing URL; lookup happens via the SHA-256 hash of the
# normalized URL (index), not via the URL itself (TEXT column).
require 'digest'

class HelpdeskPhishingUrl < HelpdeskApplicationRecord
  # Feed sources of the mirror
  SOURCES = %w[phishtank phishing_database].freeze

  BATCH_SIZE = 1000

  validates :url,      :presence => true
  validates :url_hash, :presence => true, :uniqueness => true

  # Normalizes a URL for comparison:
  # lowercases scheme and host, removes the fragment, removes trailing slashes of the path.
  def self.normalize(url)
    u = url.to_s.strip
    return '' if u.empty?

    begin
      parsed = URI.parse(u)
      parsed.scheme = parsed.scheme&.downcase
      parsed.host = parsed.host&.downcase
      parsed.fragment = nil
      normalized = parsed.to_s
    rescue URI::Error
      normalized = u
    end

    normalized.sub(%r{/+\z}, '')
  end

  def self.hash_for(url)
    Digest::SHA256.hexdigest(normalize(url))
  end

  # Looks up a URL in the mirror. Returns the record or nil.
  def self.lookup(url)
    normalized = normalize(url)
    return nil if normalized.empty?

    find_by(:url_hash => Digest::SHA256.hexdigest(normalized))
  end

  # Is the source (or the whole mirror) older than the interval or empty?
  def self.stale?(interval_hours, source = nil)
    scope = source.present? ? where(:source => source) : all
    last_import = scope.maximum(:imported_at)
    return true if last_import.nil?

    last_import < interval_hours.to_i.hours.ago
  end

  # Replaces all entries of one source in a transaction.
  # Duplicates from other sources (same url_hash) are skipped by insert_all
  # (unique index). Returns the number of rows.
  def self.replace_source!(source, rows)
    with_utf8mb4_connection do
      transaction do
        where(:source => source).delete_all
        rows.each_slice(BATCH_SIZE) do |batch|
          insert_all(batch)
        end
      end
    end
    rows.size
  end

  # Switches the session to utf8mb4 during the import.
  # Background: Redmine's database.yml uses encoding utf8 (= utf8mb3); the server
  # then rejects 4-byte UTF-8 (homoglyph domains in the feeds) already at the
  # connection level, even though the table is utf8mb4.
  def self.with_utf8mb4_connection
    conn = connection
    return yield unless conn.adapter_name =~ /mysql/i

    previous = conn.select_value('SELECT @@character_set_client').to_s
    return yield if previous == 'utf8mb4'

    conn.execute('SET NAMES utf8mb4')
    begin
      yield
    ensure
      conn.execute("SET NAMES #{previous}") if previous.present?
    end
  end
end

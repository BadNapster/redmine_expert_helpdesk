# Microsoft Graph client for the helpdesk mail fetch and send.
#
# Uses the OAuth2 client-credentials flow (app-only) against Azure AD / Entra ID.
# The credentials (tenant ID, client ID, client secret) are maintained centrally in
# the plugin settings. The access token is cached in the Rails cache
# (Redis in production).
#
# Required application permissions of the app registration:
#   - Mail.ReadWrite (read mails and move them into subfolders)
#   - Mail.Send      (send replies and autoresponders)
# Access should be restricted to the helpdesk mailboxes via an
# ApplicationAccessPolicy (see README).

require 'net/http'
require 'uri'
require 'json'
require 'base64'
require 'digest'

module RedmineExpertHelpdesk
  class GraphClient
    GRAPH_BASE  = 'https://graph.microsoft.com/v1.0'.freeze
    TOKEN_CACHE_PREFIX = 'redmine_expert_helpdesk/graph_token'.freeze

    # GraphError inherits from ProviderError so callers can rescue the common
    # provider error and still catch Graph failures.
    class GraphError < MailProvider::ProviderError; end

    class ConfigurationError < GraphError; end

    def initialize(settings = nil)
      @settings = settings || Setting.plugin_redmine_expert_helpdesk
    end

    def configured?
      %w[tenant_id client_id client_secret].all? { |k| @settings[k].present? }
    end

    # Returns the messages of a folder (oldest first), at most +top+ messages.
    # +folder+ is the display name of the folder (e.g. "Inbox" or "Posteingang").
    def list_messages(mailbox, folder, top = 25)
      folder_id = resolve_folder_id(mailbox, folder)
      query = URI.encode_www_form(
        '$top'     => top.to_i,
        '$filter'  => 'isRead eq false',
        '$orderby' => 'receivedDateTime asc',
        '$select'  => 'id,subject,from,receivedDateTime,internetMessageId'
      )
      response = get("/users/#{escape(mailbox)}/mailFolders/#{folder_id}/messages?#{query}")
      response['value'] || []
    end

    # Loads the complete message as MIME (RFC 2822) – input for the Redmine MailHandler.
    def message_mime(mailbox, message_id)
      get_raw("/users/#{escape(mailbox)}/messages/#{message_id}/$value")
    end

    # Moves a message into another folder (e.g. "Verarbeitet").
    def move_message(mailbox, message_id, destination_folder)
      folder_id = resolve_folder_id(mailbox, destination_folder)
      post("/users/#{escape(mailbox)}/messages/#{message_id}/move",
           { 'destinationId' => folder_id })
    end

    # Marks a message as read.
    def mark_as_read(mailbox, message_id)
      patch("/users/#{escape(mailbox)}/messages/#{message_id}", { 'isRead' => true })
    end

    # Lists all folder names of the mailbox (top level + direct subfolders of Inbox).
    # Returns a sorted array of display names.
    def list_folders(mailbox)
      query = URI.encode_www_form('$select' => 'id,displayName', '$top' => 100)
      top_level = (get("/users/#{escape(mailbox)}/mailFolders?#{query}")['value'] || [])
                  .map { |f| f['displayName'] }

      inbox_children = begin
        (get("/users/#{escape(mailbox)}/mailFolders/inbox/childFolders?#{query}")['value'] || [])
          .map { |f| "Inbox/#{f['displayName']}" }
      rescue GraphError
        []
      end

      (top_level + inbox_children).uniq.sort
    end

    # Creates a new top-level folder in the mailbox.
    def create_folder(mailbox, folder_name)
      post("/users/#{escape(mailbox)}/mailFolders", { 'displayName' => folder_name })
    end

    # Looks up a folder and creates it if it does not exist yet.
    # Returns the folder ID.
    def find_or_create_folder(mailbox, folder_name)
      return nil if folder_name.blank?
      resolve_folder_id(mailbox, folder_name)
    rescue GraphError
      result = create_folder(mailbox, folder_name)
      # Clear the cache so resolve_folder_id loads the real entry on the next call
      cache_key = "redmine_expert_helpdesk/folder/#{mailbox}/#{folder_name}"
      Rails.cache.delete(cache_key)
      result['id']
    end

    # Sends a mail on behalf of the mailbox (it lands in "Gesendete Elemente").
    # +message+ corresponds to the Graph message structure (subject, body, toRecipients, ...).
    def send_mail(mailbox, message, save_to_sent_items = true)
      post("/users/#{escape(mailbox)}/sendMail",
           { 'message' => message, 'saveToSentItems' => save_to_sent_items })
    end

    # Sends a mail as a raw RFC 2822 MIME message via the Graph MIME endpoint.
    # This uses Content-Type: text/plain plus a Base64-encoded MIME body.
    # This route is more reliable for inline images (CID), because Exchange rewrites
    # the HTML in JSON requests and in doing so can decouple cid: references.
    def send_mail_mime(mailbox, mime_string)
      encoded = Base64.strict_encode64(mime_string)
      uri  = URI("#{GRAPH_BASE}/users/#{escape(mailbox)}/sendMail")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = true
      http.open_timeout = 15
      http.read_timeout = 60
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Bearer #{access_token}"
      req['Content-Type']  = 'text/plain'
      req.body = encoded
      response = http.request(req)
      unless response.is_a?(Net::HTTPSuccess)
        raise GraphError.new("MIME mail send failed (#{response.code}): POST /sendMail" \
                             "#{graph_error_detail(response.body)}",
                             response.code.to_i, response.body)
      end
      response
    end

    # Determines the folder ID from the display name. Well-known standard folders
    # ("inbox" etc.) are used directly as a well-known name.
    def resolve_folder_id(mailbox, folder)
      return 'inbox' if folder.blank? || folder.casecmp('inbox').zero? || folder.casecmp('posteingang').zero?

      cache_key = "redmine_expert_helpdesk/folder/#{mailbox}/#{folder}"
      cached = Rails.cache.read(cache_key)
      return cached if cached

      query = URI.encode_www_form(
        '$filter' => "displayName eq '#{folder.gsub("'", "''")}'",
        '$select' => 'id,displayName'
      )
      response = get("/users/#{escape(mailbox)}/mailFolders?#{query}")
      entry = (response['value'] || []).first
      raise GraphError.new("Folder '#{folder}' not found in mailbox #{mailbox}") unless entry

      Rails.cache.write(cache_key, entry['id'], :expires_in => 12.hours)
      entry['id']
    end

    # --- Token-Handling -----------------------------------------------------

    def access_token
      cache_key = token_cache_key
      cached = Rails.cache.read(cache_key)
      return cached if cached

      raise ConfigurationError.new('Helpdesk: tenant ID, client ID or client secret not configured') unless configured?

      uri = URI("https://login.microsoftonline.com/#{@settings['tenant_id']}/oauth2/v2.0/token")
      response = Net::HTTP.post_form(uri,
                                     'client_id'     => @settings['client_id'],
                                     'client_secret' => @settings['client_secret'],
                                     'scope'         => 'https://graph.microsoft.com/.default',
                                     'grant_type'    => 'client_credentials')

      body = JSON.parse(response.body) rescue {}
      unless response.is_a?(Net::HTTPSuccess) && body['access_token']
        raise GraphError.new("Token fetch failed: #{body['error_description'] || response.code}",
                             response.code.to_i, response.body)
      end

      # Let the token expire a little earlier than specified by Azure
      ttl = [body['expires_in'].to_i - 120, 60].max
      Rails.cache.write(cache_key, body['access_token'], :expires_in => ttl.seconds)
      body['access_token']
    end

    # The cache key includes a fingerprint of the credentials, so rotating the
    # client secret takes effect immediately instead of after the cached token
    # expires.
    def token_cache_key
      fingerprint = Digest::SHA256.hexdigest(
        [@settings['tenant_id'], @settings['client_id'], @settings['client_secret']].join('|')
      )[0, 12]
      "#{TOKEN_CACHE_PREFIX}/#{fingerprint}"
    end

    private

    def escape(value)
      URI.encode_www_form_component(value.to_s)
    end

    def get(path)
      JSON.parse(request(:get, path).body)
    end

    def get_raw(path)
      request(:get, path).body
    end

    def post(path, payload)
      response = request(:post, path, payload)
      response.body.present? ? (JSON.parse(response.body) rescue {}) : {}
    end

    def patch(path, payload)
      response = request(:patch, path, payload)
      response.body.present? ? (JSON.parse(response.body) rescue {}) : {}
    end

    def request(method, path, payload = nil)
      uri = URI("#{GRAPH_BASE}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 15
      http.read_timeout = 60

      req = case method
            when :get   then Net::HTTP::Get.new(uri)
            when :post  then Net::HTTP::Post.new(uri)
            when :patch then Net::HTTP::Patch.new(uri)
            end
      req['Authorization'] = "Bearer #{access_token}"
      req['Accept'] = 'application/json'
      if payload
        req['Content-Type'] = 'application/json'
        req.body = payload.to_json
      end

      response = http.request(req)
      unless response.is_a?(Net::HTTPSuccess)
        raise GraphError.new("Graph request failed (#{response.code}): #{method.to_s.upcase} #{path}" \
                             "#{graph_error_detail(response.body)}",
                             response.code.to_i, response.body)
      end
      response
    end

    # Graph puts the actual reason in the response body, not in the status code.
    # A 403 is either "ErrorAccessDenied" (the RBAC scope does not cover this
    # mailbox) or "MailboxNotEnabledForRESTAPI" (the mailbox is inactive,
    # soft-deleted or hosted on-premises) - completely different problems that
    # need completely different fixes, and the status alone tells them apart not
    # at all. Without this the operator only ever sees "(403)".
    def graph_error_detail(body)
      error = JSON.parse(body.to_s)['error'] rescue nil
      return '' unless error.is_a?(Hash)

      detail = [error['code'], error['message']].map(&:to_s).reject(&:empty?).join(': ')
      detail.empty? ? '' : " - #{detail}"
    end
  end
end

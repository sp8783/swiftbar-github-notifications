#!/usr/bin/env ruby
# frozen_string_literal: true

# <xbar.title>GitHub Notifications Inbox</xbar.title>
# <xbar.version>1.0.0</xbar.version>
# <xbar.author>swiftbar-github-notifications</xbar.author>
# <xbar.desc>Shows GitHub Notifications Inbox items, including read items that remain in the inbox.</xbar.desc>
# <xbar.dependencies>ruby</xbar.dependencies>

require "base64"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"

CONFIG_DIRECTORY = File.expand_path("~/.config/swiftbar-github-notifications")
TOKEN_PATH = File.join(CONFIG_DIRECTORY, "token")
INCLUDE_READ_PATH = File.join(CONFIG_DIRECTORY, "include_read")
# Files in the Plugin Folder are imported as plugins. Keep the image in a hidden
# subdirectory, which SwiftBar ignores while this script can still read it.
ICON_PATH = File.expand_path(".assets/github-mark.png", __dir__)
API_ROOT = "https://api.github.com"
NOTIFICATIONS_PAGE_URL = "https://github.com/notifications"
MAX_VISIBLE_NOTIFICATIONS = 20
USER_AGENT = "swiftbar-github-notifications"

class TokenError < StandardError; end

class ApiError < StandardError
  attr_reader :status

  def initialize(status, message)
    super(message)
    @status = status
  end
end

# Keep the fields used for display explicit while retaining GitHub's response
# order (which is already descending by updated_at for this endpoint).
InboxNotification = Struct.new(
  :subject_url,
  :repository_name,
  :repository_url,
  :title,
  :type,
  :unread,
  :updated_at,
  keyword_init: true
) do
  def self.from_api(payload)
    payload = {} unless payload.is_a?(Hash)
    subject = payload["subject"].is_a?(Hash) ? payload["subject"] : {}
    repository = payload["repository"].is_a?(Hash) ? payload["repository"] : {}

    new(
      subject_url: subject["url"],
      repository_name: repository["full_name"],
      repository_url: repository["html_url"],
      title: subject["title"],
      type: subject["type"],
      unread: payload["unread"] == true,
      updated_at: payload["updated_at"]
    )
  end
end

class GithubNotifications
  def initialize(token, include_read:)
    @token = token
    @include_read = include_read
  end

  # The REST response does not expose whether a read notification has also been
  # marked Done, even when `all=true` includes read notifications.
  def fetch_all
    notifications = []
    next_url = "#{API_ROOT}/notifications?all=#{@include_read}&per_page=50&page=1"

    while next_url
      response = get(next_url)
      parsed = JSON.parse(response.body)
      raise ApiError.new(response.code, "GitHub returned an unexpected response.") unless parsed.is_a?(Array)

      notifications.concat(parsed.map { |payload| InboxNotification.from_api(payload) })
      next_url = next_page_url(response["link"])
    end

    notifications
  end

  private

  def get(url)
    uri = URI.parse(url)
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/vnd.github+json"
    request["Authorization"] = "Bearer #{@token}"
    request["X-GitHub-Api-Version"] = "2022-11-28"
    request["User-Agent"] = USER_AGENT

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 15
    response = http.start { |client| client.request(request) }

    return response if response.is_a?(Net::HTTPSuccess)

    raise ApiError.new(response.code, api_error_message(response.body))
  end

  def api_error_message(body)
    parsed = JSON.parse(body)
    message = parsed["message"] if parsed.is_a?(Hash)
    return message if message.is_a?(String) && !message.empty?

    "GitHub API request failed."
  rescue JSON::ParserError
    "GitHub API request failed."
  end

  def next_page_url(link_header)
    return nil if link_header.nil? || link_header.empty?

    next_link = link_header.split(",").find { |link| link.include?("rel=\"next\"") }
    return nil unless next_link

    next_link[/<([^>]+)>/, 1]
  end
end

def token
  raise TokenError, "Token file not found: #{TOKEN_PATH}" unless File.file?(TOKEN_PATH)

  value = File.read(TOKEN_PATH).strip
  raise TokenError, "Token file is empty: #{TOKEN_PATH}" if value.empty?

  value
rescue Errno::EACCES => error
  raise TokenError, "Cannot read token file: #{error.message}"
end

def include_read?
  return true unless File.file?(INCLUDE_READ_PATH)

  File.read(INCLUDE_READ_PATH).strip != "false"
rescue Errno::EACCES
  true
end

def toggle_include_read
  FileUtils.mkdir_p(CONFIG_DIRECTORY)
  File.write(INCLUDE_READ_PATH, include_read? ? "false\n" : "true\n")
end

# SwiftBar uses `|` to start item parameters. Keep arbitrary GitHub titles in the
# visible label without allowing them to alter the menu format.
def menu_text(value)
  value.to_s
       .encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
       .gsub(/[\r\n]+/, " ")
       .gsub("|", "¦")
       .gsub(/\s+/, " ")
       .strip
end

def template_image_parameter
  return nil unless File.file?(ICON_PATH)

  image = File.binread(ICON_PATH)
  return nil if image.empty?

  Base64.strict_encode64(image)
rescue Errno::EACCES, Errno::EISDIR
  nil
end

def print_menu_bar(unread_count, total_count)
  image = template_image_parameter
  if image
    puts "\u2009#{unread_count}/#{total_count} | templateImage=#{image}"
  else
    puts "GH #{unread_count}/#{total_count}"
  end
end

def type_label(type)
  case type
  when "PullRequest" then "PR"
  when "Issue" then "Issue"
  else
    label = menu_text(type).gsub(/(?<=[a-z])(?=[A-Z])/, " ")
    label.empty? ? "Notification" : label
  end
end

def subject_number(subject_url)
  return nil if subject_url.nil?

  path = URI.parse(subject_url).path
  match = path.match(%r{/(?:issues|pulls|discussions|releases)/(\d+)(?:\z|/)})
  match && match[1]
rescue URI::InvalidURIError
  nil
end

def subject_html_url(notification)
  subject_url = notification.subject_url
  repository_url = notification.repository_url
  return repository_url || NOTIFICATIONS_PAGE_URL if subject_url.nil? || subject_url.empty?

  uri = URI.parse(subject_url)
  path = uri.path
  match = path.match(%r{\A/repos/([^/]+)/([^/]+)/(issues|pulls|discussions|releases)/(\d+)\z})

  if match
    owner, repository, resource, number = match.captures
    web_resource = notification.type == "PullRequest" ? "pull" : resource
    return "https://github.com/#{owner}/#{repository}/#{web_resource}/#{number}"
  end

  commit_match = path.match(%r{\A/repos/([^/]+)/([^/]+)/commits/([^/]+)\z})
  if commit_match
    owner, repository, sha = commit_match.captures
    return "https://github.com/#{owner}/#{repository}/commit/#{sha}"
  end

  repository_url || NOTIFICATIONS_PAGE_URL
rescue URI::InvalidURIError
  repository_url || NOTIFICATIONS_PAGE_URL
end

def repository_summary(notification)
  repository_name = notification.repository_name || "Unknown repository"
  number = subject_number(notification.subject_url)
  number ? "#{repository_name} ##{number}" : repository_name
end

def print_notification(notification)
  title = menu_text(notification.title)
  title = "Untitled notification" if title.empty?
  unread_marker = notification.unread ? "● " : ""
  label = "#{unread_marker}[#{type_label(notification.type)}] #{title} — #{menu_text(repository_summary(notification))}"
  url = subject_html_url(notification)

  puts "#{label} | href=#{url}"
end

def toggle_include_read_menu_item(include_read)
  action = "bash=#{File.expand_path(__FILE__)} param1=--toggle-include-read terminal=false refresh=true"
  label = include_read ? "Hide read notifications" : "Show read notifications"
  puts "#{label} | #{action}"
end

def print_notifications_menu(notifications, include_read:)
  unread_count = notifications.count(&:unread)
  print_menu_bar(unread_count, notifications.length)
  puts "---"
  puts "GitHub Notifications"
  puts "---"

  if notifications.empty?
    puts "Inbox is empty"
  else
    notifications.first(MAX_VISIBLE_NOTIFICATIONS).each { |notification| print_notification(notification) }
  end

  if notifications.length > MAX_VISIBLE_NOTIFICATIONS
    puts "---"
    puts "Show all in GitHub | href=#{NOTIFICATIONS_PAGE_URL}"
  end

  puts "---"
  toggle_include_read_menu_item(include_read)
end

def print_error_menu(title, detail, setup: false)
  puts "GH !"
  puts "---"
  puts "GitHub Notifications"
  puts "---"
  puts menu_text(title)
  puts menu_text(detail)

  return unless setup

  puts "---"
  puts "Create ~/.config/swiftbar-github-notifications/token"
  puts "Paste a GitHub Personal Access Token into that file."
  puts "Then run: chmod 600 ~/.config/swiftbar-github-notifications/token"
end

def run
  show_read = include_read?
  notifications = GithubNotifications.new(token, include_read: show_read).fetch_all
  print_notifications_menu(notifications, include_read: show_read)
rescue TokenError => error
  print_error_menu("GitHub token is not configured", error.message, setup: true)
rescue ApiError => error
  print_error_menu("GitHub API error (HTTP #{error.status})", error.message)
rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED,
       Errno::ECONNRESET, Errno::ETIMEDOUT, EOFError, OpenSSL::SSL::SSLError => error
  print_error_menu("Network error", "#{error.class}: #{error.message}")
rescue JSON::ParserError => error
  print_error_menu("Invalid response from GitHub", error.message)
rescue StandardError => error
  print_error_menu("Unexpected error", "#{error.class}: #{error.message}")
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ["--toggle-include-read"]
    toggle_include_read
  else
    run
  end
end

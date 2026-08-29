# frozen_string_literal: true

module ReleaseAutomation
  CHANNELS = %w[stable beta].freeze
  STABLE_VERSION_REGEX = /\A\d+\.\d+\.\d+\z/
  BETA_VERSION_REGEX = /\A\d+\.\d+\.\d+-beta\.\d+\z/

  module_function

  def normalize_channel(value)
    channel = value.to_s.strip.downcase
    CHANNELS.include?(channel) ? channel : nil
  end

  def normalized_version(value)
    normalized = value.to_s.strip.sub(/\Av/, "")
    normalized.empty? ? nil : normalized
  end

  def release_tag(version)
    normalized = normalized_version(version)
    raise ArgumentError, "Release tag requires a version" if normalized.nil?

    "v#{normalized}"
  end

  def stable_version?(value)
    normalized = normalized_version(value)
    !normalized.nil? && STABLE_VERSION_REGEX.match?(normalized)
  end

  def beta_version?(value)
    normalized = normalized_version(value)
    !normalized.nil? && BETA_VERSION_REGEX.match?(normalized)
  end

  def validate_version!(channel:, version:)
    normalized = normalized_version(version)
    raise ArgumentError, "Release version is required" if normalized.nil?

    case normalize_channel(channel)
    when "stable"
      raise ArgumentError, "Stable releases must use x.y.z" unless stable_version?(normalized)
    when "beta"
      raise ArgumentError, "Beta releases must use x.y.z-beta.N" unless beta_version?(normalized)
    else
      raise ArgumentError, "Unknown release channel: #{channel}"
    end

    normalized
  end

  def patch_bump(version)
    normalized = normalized_version(version)
    match = STABLE_VERSION_REGEX.match(normalized)
    raise ArgumentError, "Cannot patch bump non-semver version: #{version}" unless match

    major, minor, patch = normalized.split(".").map(&:to_i)
    "#{major}.#{minor}.#{patch + 1}"
  end

  def suggested_version(channel:, latest_version:, fallback_version: nil)
    normalized_latest = normalized_version(latest_version)
    base =
      if normalized_latest.nil?
        normalized_fallback = normalized_version(fallback_version)
        raise ArgumentError, "Cannot suggest version without a stable fallback version" unless stable_version?(normalized_fallback)

        normalized_fallback
      else
        patch_bump(normalized_latest)
      end

    normalize_channel(channel) == "beta" ? "#{base}-beta.1" : base
  end

  def archive_basename(app_name:, version:, build:)
    normalized = normalized_version(version)
    raise ArgumentError, "Archive basename requires a version" if normalized.nil?

    "#{app_name}-#{normalized}-#{build}"
  end

  def replace_pbx_assignment(content:, key:, value:)
    pattern = /^(\t+)#{Regexp.escape(key)} = [^;]+;/
    raise ArgumentError, "#{key} not found in Xcode project" unless content.match?(pattern)

    content.gsub(pattern, "\\1#{key} = #{value};")
  end

  def replace_xcconfig_assignment(content:, key:, value:)
    pattern = /^#{Regexp.escape(key)}\s*=.*$/
    line = "#{key} = #{value}"
    return "#{line}\n#{content}" unless content.match?(pattern)

    content.sub(pattern, line)
  end

  def first_release_notes(version:)
    normalized = normalized_version(version)
    <<~NOTES
      First public release of Omacy #{normalized}.

      A macOS screensaver that plays Omarchy's ASCII text-effects loop: your logo, or any art, animated by the 37 Terminal Text Effects.

      - Host app plus a System Settings screensaver extension
      - All 37 effects on a Metal cell grid
      - Paste ASCII, or convert a PNG or SVG to block or Braille
      - Signed and notarized Developer ID build
      - In-app updates via Sparkle from GitHub Releases

      Requires macOS 15 (Sequoia) or later. Put `Omacy.app` in `/Applications`, then register and enable it from the host.
    NOTES
  end

  def github_release_asset_url(repo:, tag:, filename:)
    "https://github.com/#{repo}/releases/download/#{tag}/#{filename}"
  end

  def sparkle_zip_tag(filename)
    match = /\AOmacy-(.+)-(\d+)\.zip\z/.match(filename.to_s)
    match ? release_tag(match[1]) : nil
  end

  def rewrite_appcast_enclosures(content:, repo:, filename_to_tag:)
    content.gsub(/url="[^"]+\/([^"\/]+)"/) do
      filename = Regexp.last_match(1)
      tag = filename_to_tag[filename] || sparkle_zip_tag(filename)
      tag ? %(url="#{github_release_asset_url(repo: repo, tag: tag, filename: filename)}") : Regexp.last_match(0)
    end
  end
end

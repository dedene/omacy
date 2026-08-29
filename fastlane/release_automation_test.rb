# frozen_string_literal: true

require_relative "release_automation"

def assert(condition, message = "assertion failed")
  raise message unless condition
end

def assert_equal(expected, actual, message = nil)
  return if expected == actual

  raise(message || "Expected #{expected.inspect}, got #{actual.inspect}")
end

def assert_nil(actual, message = nil)
  return if actual.nil?

  raise(message || "Expected nil, got #{actual.inspect}")
end

def assert_match(pattern, actual, message = nil)
  return if pattern.match?(actual)

  raise(message || "Expected #{actual.inspect} to match #{pattern.inspect}")
end

assert_equal "stable", ReleaseAutomation.normalize_channel(" stable ")
assert_equal "beta", ReleaseAutomation.normalize_channel("BETA")
assert_nil ReleaseAutomation.normalize_channel("nightly")

assert_equal "v1.2.3", ReleaseAutomation.release_tag("1.2.3")
assert_equal "v1.2.3", ReleaseAutomation.release_tag("v1.2.3")
assert_nil ReleaseAutomation.normalized_version(nil)
assert_nil ReleaseAutomation.normalized_version("")

assert ReleaseAutomation.stable_version?("1.2.3")
assert_equal false, ReleaseAutomation.stable_version?("1.2.3-beta.1")
assert_equal "1.2.3", ReleaseAutomation.validate_version!(channel: "stable", version: "v1.2.3")

assert ReleaseAutomation.beta_version?("1.2.3-beta.4")
assert_equal false, ReleaseAutomation.beta_version?("1.2.3")
assert_equal "1.2.3-beta.4", ReleaseAutomation.validate_version!(channel: "beta", version: "v1.2.3-beta.4")

assert_equal "1.2.4", ReleaseAutomation.patch_bump("1.2.3")
assert_equal "1.2.4", ReleaseAutomation.suggested_version(channel: "stable", latest_version: "v1.2.3")
assert_equal "1.2.4-beta.1", ReleaseAutomation.suggested_version(channel: "beta", latest_version: "1.2.3")
assert_equal "0.1.0", ReleaseAutomation.suggested_version(channel: "stable", latest_version: nil, fallback_version: "0.1.0")
assert_equal "0.1.0-beta.1", ReleaseAutomation.suggested_version(channel: "beta", latest_version: "", fallback_version: "0.1.0")
assert_equal "Omacy-0.1.0-12", ReleaseAutomation.archive_basename(app_name: "Omacy", version: "v0.1.0", build: "12")

pbx = "\t\t\t\tMARKETING_VERSION = 0.1.0;\n\t\t\t\tMARKETING_VERSION = 0.1.0;\n"
updated = ReleaseAutomation.replace_pbx_assignment(content: pbx, key: "MARKETING_VERSION", value: "0.2.0")
assert_equal "\t\t\t\tMARKETING_VERSION = 0.2.0;\n\t\t\t\tMARKETING_VERSION = 0.2.0;\n", updated

xcconfig = "CURRENT_PROJECT_VERSION = 260829.1443\n"
assert_equal "CURRENT_PROJECT_VERSION = 42\n", ReleaseAutomation.replace_xcconfig_assignment(
  content: xcconfig,
  key: "CURRENT_PROJECT_VERSION",
  value: "42"
)

notes = ReleaseAutomation.first_release_notes(version: "0.1.0")
assert_match(/Omacy 0\.1\.0/, notes)
assert_match(/macOS 15/, notes)

puts "ok"

#!/usr/bin/env ruby
# frozen_string_literal: true
#
# bootstrap-xcodeproj.rb
#
# ONE-TIME bootstrap that created JUMPjet.xcodeproj.
#
# Read this before you reach for it. The committed `JUMPjet.xcodeproj` is the
# source of truth, and ordinary changes (targets, capabilities, resources, build
# settings) are made in Xcode and committed as a diff to `project.pbxproj`.
#
# This script exists so the project's ORIGIN is auditable rather than a binary
# blob that appeared one day: it records exactly which targets, settings and
# package references the project started with. Running it again OVERWRITES the
# project and discards every change made in Xcode since. Do not run it to
# "regenerate" anything.
#
#   gem install --user-install xcodeproj
#   ruby Tools/bootstrap-xcodeproj.rb

require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
PROJECT_PATH = File.join(ROOT, "JUMPjet.xcodeproj")

# iOS 17 is the build plan's floor: it is what the Observation framework needs,
# and it is two major versions of reach wider than building against the current
# SDK's minimum would be.
DEPLOYMENT_TARGET = "17.0"
BUNDLE_ID = "com.marcdeller.jumpjet"
SWIFT_VERSION = "6.2"

# Phase 1's five. JetEngine, Neural, Analysis and Movie join in later phases.
PACKAGES = %w[
  JumpjetCore
  JumpjetHUD
  JumpjetParse
  JumpjetFetch
  JumpjetViewer
].freeze

BASE_SETTINGS = {
  "SWIFT_VERSION" => SWIFT_VERSION,
  "SWIFT_STRICT_CONCURRENCY" => "complete",
  "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY" => "YES",
  "IPHONEOS_DEPLOYMENT_TARGET" => DEPLOYMENT_TARGET,
  # iPhone and iPad. No Mac Catalyst and no visionOS for v1: the physics core
  # is tuned for a phone's thermal envelope and neither has been measured.
  "TARGETED_DEVICE_FAMILY" => "1,2",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "SWIFT_EMIT_LOC_STRINGS" => "YES",
}.freeze

project = Xcodeproj::Project.new(PROJECT_PATH)
project.build_configurations.each do |config|
  BASE_SETTINGS.each { |key, value| config.build_settings[key] = value }
  config.build_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] =
    config.name == "Debug" ? "DEBUG" : ""
end

# ---------------------------------------------------------------------------
# Local Swift packages
#
# The modules stay as local SPM packages rather than as Xcode framework targets
# so each can be tested with `swift test` on the host, with no simulator. That
# turns the inner loop from tens of seconds into one, and it is what
# Tools/test-all.sh depends on.
# ---------------------------------------------------------------------------
package_refs = PACKAGES.map do |name|
  ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  ref.relative_path = "Packages/#{name}"
  project.root_object.package_references << ref
  ref
end

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
app = project.new_target(:application, "JUMPjet", :ios, DEPLOYMENT_TARGET)
unit_tests = project.new_target(:unit_test_bundle, "JUMPjetTests", :ios, DEPLOYMENT_TARGET)
ui_tests = project.new_target(:ui_test_bundle, "JUMPjetUITests", :ios, DEPLOYMENT_TARGET)

{
  app => BUNDLE_ID,
  unit_tests => "#{BUNDLE_ID}.tests",
  ui_tests => "#{BUNDLE_ID}.uitests",
}.each do |target, identifier|
  target.build_configurations.each do |config|
    config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = identifier
    config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
    config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
    config.build_settings["SWIFT_VERSION"] = SWIFT_VERSION
    config.build_settings["SWIFT_STRICT_CONCURRENCY"] = "complete"
  end
end

app.build_configurations.each do |config|
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "App/Resources/Info.plist"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  config.build_settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
  config.build_settings["CURRENT_PROJECT_VERSION"] = "1"
  config.build_settings["MARKETING_VERSION"] = "0.1.0"
end

unit_tests.build_configurations.each do |config|
  config.build_settings["TEST_HOST"] =
    "$(BUILT_PRODUCTS_DIR)/JUMPjet.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/JUMPjet"
  config.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
end

ui_tests.build_configurations.each do |config|
  config.build_settings["TEST_TARGET_NAME"] = "JUMPjet"
end

# ---------------------------------------------------------------------------
# Sources and resources
# ---------------------------------------------------------------------------
def add_sources(project, target, group_path, dir)
  group = project.main_group.find_subpath(group_path, true)
  group.set_source_tree("SOURCE_ROOT")
  Dir.glob(File.join(dir, "**", "*.swift")).sort.each do |file|
    ref = group.new_reference(file)
    target.add_file_references([ref])
  end
end

add_sources(project, app, "App/Sources", File.join(ROOT, "App/Sources"))
add_sources(project, unit_tests, "App/Tests", File.join(ROOT, "App/Tests"))
add_sources(project, ui_tests, "App/UITests", File.join(ROOT, "App/UITests"))

resources_group = project.main_group.find_subpath("App/Resources", true)
resources_group.set_source_tree("SOURCE_ROOT")
assets = resources_group.new_reference(File.join(ROOT, "App/Resources/Assets.xcassets"))
app.add_resources([assets])
# Referenced by INFOPLIST_FILE, so the plist is listed for visibility in the
# navigator but must NOT be a member of any build phase.
resources_group.new_reference(File.join(ROOT, "App/Resources/Info.plist"))

# Keep the loose repository files visible in Xcode's navigator.
docs_group = project.main_group.find_subpath("Documentation", true)
docs_group.set_source_tree("SOURCE_ROOT")
%w[README.md CLAUDE.md Docs/JUMPJET_BUILD_PLAN.md Docs/CHANGELOG.md Fixtures/MANIFEST.md]
  .each do |file|
    next unless File.exist?(File.join(ROOT, file))
    docs_group.new_reference(File.join(ROOT, file))
  end

# ---------------------------------------------------------------------------
# Package product dependencies
# ---------------------------------------------------------------------------
PACKAGES.each_with_index do |name, index|
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.product_name = name
  dependency.package = package_refs[index]
  app.package_product_dependencies << dependency
end

# ---------------------------------------------------------------------------
# Test target wiring
# ---------------------------------------------------------------------------
unit_tests.add_dependency(app)
ui_tests.add_dependency(app)

project.save

# ---------------------------------------------------------------------------
# Shared scheme
# ---------------------------------------------------------------------------
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(unit_tests)
scheme.add_test_target(ui_tests)
scheme.set_launch_target(app)
scheme.test_action.code_coverage_enabled = true
scheme.save_as(PROJECT_PATH, "JUMPjet", true)

puts "Created #{PROJECT_PATH}"
puts "  targets:  #{project.targets.map(&:name).join(', ')}"
puts "  packages: #{PACKAGES.join(', ')}"

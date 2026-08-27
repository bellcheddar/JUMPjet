#!/usr/bin/env ruby
# frozen_string_literal: true
#
# configure-signing.rb
#
# Sets the Apple developer team and MANUAL App Store signing on the app target.
#
# Manual rather than automatic, and not by preference. Automatic signing asks
# Apple for a DEVELOPMENT profile when archiving, and Apple will not issue one
# to a team with no registered devices, so the archive fails outright on an
# account that has never had a device added. Setting an identity by hand then
# conflicts with the automatic style, so the whole thing has to be manual: an
# explicit distribution certificate and an App Store profile.
#
# That lesson is BOFFIN's, paid for there and applied here rather than repeated.
#
# IDEMPOTENT. Re-run after any change to the project's signing.
#
#   ruby Tools/configure-signing.rb

require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
TEAM = "SYNV8TWB5Z"                       # Marc C. Deller
PROFILE = "JUMPjet App Store"

project = Xcodeproj::Project.open(File.join(ROOT, "JUMPjet.xcodeproj"))
app = project.targets.find { |t| t.name == "JUMPjet" } or abort "no JUMPjet target"

app.build_configurations.each do |config|
  settings = config.build_settings
  settings["DEVELOPMENT_TEAM"] = TEAM

  if config.name == "Release"
    settings["CODE_SIGN_STYLE"] = "Manual"
    # Xcode's default when nothing is set is "Apple Development", which cannot
    # sign an App Store archive. Naming the distribution identity explicitly is
    # what stops Release quietly resolving to the wrong one.
    settings["CODE_SIGN_IDENTITY"] = "Apple Distribution"
    settings["CODE_SIGN_IDENTITY[sdk=iphoneos*]"] = "Apple Distribution"
    settings["PROVISIONING_PROFILE_SPECIFIER"] = PROFILE
  else
    # Debug stays automatic so a simulator build needs nothing from Apple.
    settings["CODE_SIGN_STYLE"] = "Automatic"
    settings.delete("PROVISIONING_PROFILE_SPECIFIER")
  end
end

# The test bundles are never distributed, so they stay automatic. Left explicit
# because an archive that tries to provision them fails for a reason that reads
# as being about the app.
%w[JUMPjetTests JUMPjetUITests].each do |name|
  target = project.targets.find { |t| t.name == name } or next
  target.build_configurations.each do |config|
    config.build_settings["DEVELOPMENT_TEAM"] = TEAM
    config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
    config.build_settings["CODE_SIGN_IDENTITY"] = ""
  end
end

project.save

puts "team:    #{TEAM}"
app.build_configurations.each do |config|
  puts "  #{config.name.ljust(8)} style=#{config.build_settings['CODE_SIGN_STYLE']} " \
       "identity=#{config.build_settings['CODE_SIGN_IDENTITY'] || '(default)'} " \
       "profile=#{config.build_settings['PROVISIONING_PROFILE_SPECIFIER'] || '(none)'}"
end

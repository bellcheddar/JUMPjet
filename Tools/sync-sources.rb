#!/usr/bin/env ruby
# frozen_string_literal: true
#
# sync-sources.rb
#
# Adds any App/Sources, App/Tests or App/UITests Swift file that is on disk but
# not in its target, and reports any that are in the target but no longer on
# disk.
#
# IDEMPOTENT and safe to re-run. It exists because a new file added to the
# repository is invisible to Xcode until something puts it in project.pbxproj,
# and the failure is "cannot find X in scope" for a type that is plainly right
# there, which reads as a compiler problem rather than a project one.
#
#   ruby Tools/sync-sources.rb

require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, "JUMPjet.xcodeproj"))

TARGETS = {
  "JUMPjet" => "App/Sources",
  "JUMPjetTests" => "App/Tests",
  "JUMPjetUITests" => "App/UITests",
}.freeze

added = []
missing = []

TARGETS.each do |target_name, directory|
  target = project.targets.find { |t| t.name == target_name }
  next unless target

  group = project.main_group.find_subpath(directory, true)
  group.set_source_tree("SOURCE_ROOT")

  in_target = target.source_build_phase.files_references.map { |f| f.real_path.to_s }
  on_disk = Dir.glob(File.join(ROOT, directory, "**", "*.swift")).sort

  (on_disk - in_target).each do |file|
    reference = group.files.find { |f| f.real_path.to_s == file } || group.new_reference(file)
    target.add_file_references([reference])
    added << "#{target_name}: #{File.basename(file)}"
  end

  (in_target - on_disk).each do |file|
    missing << "#{target_name}: #{File.basename(file)}"
  end
end

project.save

puts added.empty? ? "every source file is already in its target" : "added:"
added.each { |line| puts "  #{line}" }
unless missing.empty?
  puts "in the project but NOT on disk (remove them in Xcode):"
  missing.each { |line| puts "  #{line}" }
end

#!/usr/bin/env ruby
# frozen_string_literal: true
#
# add-phase2-to-xcodeproj.rb
#
# Adds Phase 2's two packages and the four model artefacts to the app target.
#
# Unlike bootstrap-xcodeproj.rb this is IDEMPOTENT and safe to re-run: it checks
# for each reference before adding it. It exists because the alternative to a
# script is a hand-edited project.pbxproj, and a diff to that file is not
# something anyone can review.
#
#   ruby Tools/add-phase2-to-xcodeproj.rb

require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, "JUMPjet.xcodeproj"))
app = project.targets.find { |t| t.name == "JUMPjet" } or abort "no JUMPjet target"

NEW_PACKAGES = %w[JumpjetNeural JumpjetEngine JumpjetAnalysis].freeze

# The model artefacts. Xcode compiles a .mlpackage to a .mlmodelc inside the
# bundle at build time, which is what ESMEmbedder.Resources.inBundle looks for.
RESOURCES = %w[
  Models/esm2_t6_8M_UR50D.mlpackage
  Models/esm2_t6_8M_UR50D.tokeniser.json
  Models/flexibility_centroids.json
  Models/torsion_tables.json
].freeze

added = []

NEW_PACKAGES.each do |name|
  path = "Packages/#{name}"
  reference = project.root_object.package_references.find do |ref|
    ref.respond_to?(:relative_path) && ref.relative_path == path
  end
  unless reference
    reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    reference.relative_path = path
    project.root_object.package_references << reference
    added << "package #{name}"
  end

  next if app.package_product_dependencies.any? { |d| d.product_name == name }

  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.product_name = name
  dependency.package = reference
  app.package_product_dependencies << dependency
  added << "product #{name}"
end

group = project.main_group.find_subpath("Models", true)
group.set_source_tree("SOURCE_ROOT")

RESOURCES.each do |relative|
  absolute = File.join(ROOT, relative)
  abort "missing #{relative}: run the Tools/coreml scripts first" unless File.exist?(absolute)

  existing = group.files.find { |f| f.path == relative || f.path == File.basename(relative) }
  reference = existing || group.new_reference(absolute)
  next if app.resources_build_phase.files_references.include?(reference)

  app.add_resources([reference])
  added << "resource #{File.basename(relative)}"
end

project.save

if added.empty?
  puts "nothing to do: the project already has Phase 2's packages and resources"
else
  puts "added:"
  added.each { |line| puts "  #{line}" }
end
puts "  app packages: #{app.package_product_dependencies.map(&:product_name).join(', ')}"
puts "  app resources: #{app.resources_build_phase.files_references.map { |f| File.basename(f.path) }.join(', ')}"

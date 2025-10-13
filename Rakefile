# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc "Build documentation website from README"
task :docs, [:readme_path, :output_dir] do |t, args|
  require_relative 'lib/docs_builder'

  readme_path = args[:readme_path] || 'README.md'
  output_dir = args[:output_dir] || 'docs'

  builder = DocsBuilder.new(
    readme_path: readme_path,
    output_dir: output_dir
  )

  builder.build
end

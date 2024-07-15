# frozen_string_literal: true

require 'plumb'
require 'debug'
require_relative 'types'
require_relative 'support/result_helpers'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.include ResultHelpers

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

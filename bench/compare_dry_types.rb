# frozen_string_literal: true

require 'bundler'
Bundler.setup(:benchmark)

require 'benchmark/ips'
require 'money'
Money.rounding_mode = BigDecimal::ROUND_HALF_EVEN
Money.default_currency = 'GBP'

require_relative './sample_data'
require_relative './plumb_hash'
require_relative './dry_types_hash'

data = SAMPLE_DATA

# Sanity-check that both do equivalent (successful) work before timing, so we're
# not comparing a happy path against an error path.
plumb_result = PlumbHash::Record.resolve(data)
warn "Plumb valid?: #{plumb_result.valid?}"
warn "Plumb errors: #{plumb_result.errors.inspect}" unless plumb_result.valid?
begin
  DryTypesHash::Record.call(data)
  warn 'Dry::Types valid?: true'
rescue StandardError => e
  warn "Dry::Types FAILED: #{e.class}: #{e.message}"
end

Benchmark.ips do |x|
  x.report('Plumb') do
    PlumbHash::Record.resolve(data)
  end
  x.report('Dry::Types') do
    DryTypesHash::Record.call(data)
  end
  x.compare!
end

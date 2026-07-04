# frozen_string_literal: true

require 'bundler'
Bundler.setup(:benchmark)

require 'benchmark/ips'
require 'money'
Money.rounding_mode = BigDecimal::ROUND_HALF_EVEN
Money.default_currency = 'GBP'
require_relative './sample_data'
require_relative './parametric_schema'
require_relative './plumb_hash'

data = SAMPLE_DATA

Benchmark.ips do |x|
  x.report('Parametric::Schema') do
    ParametricSchema::RECORD.resolve(data)
  end
  x.report('Plumb') do
    PlumbHash::Record.resolve(data)
  end
  x.compare!
end

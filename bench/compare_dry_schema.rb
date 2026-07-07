# frozen_string_literal: true

# Plumb vs Dry::Schema — the apples-to-apples comparison.
#
# Unlike Dry::Types (bare values, raises on first error), Dry::Schema shares
# Plumb's model: validate + coerce, collect ALL errors, return a Result, never
# raise. It goes one step further and resolves human-readable messages via
# `errors.to_h`. We measure both the happy path (validate + collect, no errors)
# and the error path (validate + resolve every message), since message
# resolution only does real work when there ARE errors.

require 'benchmark/ips'
require 'money'
::Money.default_currency = ::Money::Currency.new('GBP')

$LOAD_PATH.unshift File.expand_path(__dir__)
require 'sample_data'
require 'plumb_hash'
require 'dry_schema_hash'

VALID = SAMPLE_DATA

# A copy of the payload with ~9 type errors scattered across the tree (top-level,
# nested-hash, array-element). Chosen so BOTH libraries reject them and NONE hit
# the Money constructor (which raises rather than returning a clean error).
INVALID = Marshal.load(Marshal.dump(SAMPLE_DATA)).tap do |d|
  d[:supplier_name] = nil
  d[:name] = ''
  d[:tv_channels_count] = 'abc'
  d[:tv_included] = 'nope'
  d[:terms][0][:name] = 123
  d[:broadband_components][0][:download_speed] = 'fast'
  d[:broadband_components][0][:contract_length] = 'soon'
  d[:discounts][0][:period] = 'ptwelve'
  d[:max_broadband_download_speed] = 'lots'
end.freeze

# ---- sanity ---------------------------------------------------------------

def count_leaves(errors)
  case errors
  when ::Hash  then errors.values.sum { |v| count_leaves(v) }
  when ::Array then errors.sum { |v| v.is_a?(::Hash) || v.is_a?(::Array) ? count_leaves(v) : 1 }
  else 1
  end
end

plumb_ok  = PlumbHash::Record.resolve(VALID)
dry_ok    = DrySchemaHash::Record.call(VALID)
plumb_bad = PlumbHash::Record.resolve(INVALID)
dry_bad   = DrySchemaHash::Record.call(INVALID)

puts '=== sanity ==='
puts "Plumb  valid data -> valid?:   #{plumb_ok.valid?}"
puts "Dry    valid data -> success?: #{dry_ok.success?}"
puts "Plumb  invalid data -> valid?: #{plumb_bad.valid?}  (#{count_leaves(plumb_bad.errors)} error leaves)"
puts "Dry    invalid data -> success?: #{dry_bad.success?}  (#{count_leaves(dry_bad.errors.to_h)} error leaves)"
puts "Dry    messages: #{dry_bad.errors.to_h}"
puts "Plumb  errors:   #{plumb_bad.errors}"
puts

# ---- happy path: validate + collect (no errors) ---------------------------

puts '=== happy path: validate + collect errors ==='
Benchmark.ips do |x|
  x.report('Plumb') { PlumbHash::Record.resolve(VALID).errors }
  x.report('Dry::Schema') { DrySchemaHash::Record.call(VALID).errors.to_h }
  x.compare!
end

# ---- error path: validate + resolve ALL messages --------------------------

puts
puts '=== error path: validate + resolve all messages ==='
Benchmark.ips do |x|
  x.report('Plumb') { PlumbHash::Record.resolve(INVALID).errors }
  x.report('Dry::Schema') { DrySchemaHash::Record.call(INVALID).errors.to_h }
  x.compare!
end

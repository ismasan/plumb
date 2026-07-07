# frozen_string_literal: true

# Surfaces where Plumb allocates Result objects (and error strings/containers)
# while parsing. The headline metric is throwaway `Result::Invalid` objects:
# these are allocated even on SUCCESSFUL parses whenever a value matches a
# non-first branch of a union (`A | B`, `Lax::*`, `nullable`, defaults, enums),
# because `Or#call` tries each branch in turn and each miss materialises an
# Invalid that is then discarded.
#
# Three payload regimes are run over the SAME schema so the difference is purely
# the data, not the types:
#   1. first-branch valid  — every union matches its FIRST branch (the floor)
#   2. union-hit valid      — valid OUTPUT, but unions match LATER branches
#   3. fully invalid        — every field fails; Invalid propagates + errors aggregate
#
#   ruby bench/results_allocations.rb          # N=2000 records per regime
#   N=20000 ruby bench/results_allocations.rb  # scale the sample

require 'bundler'
Bundler.setup(:benchmark)
require 'plumb'
require 'memory_profiler'

# Count every Result::Invalid ever constructed, so we can report the exact
# per-record figure independently of the sampling profiler.
$invalid_allocs = 0
module CountInvalidAllocs
  def initialize(*args, **kwargs)
    $invalid_allocs += 1
    super
  end
end
Plumb::Result::Invalid.prepend(CountInvalidAllocs)

module Bench
  include Plumb::Types

  # A value union: on a miss each branch interpolates "Must be equal to #{value}"
  # (ValueClass#call), so late matches allocate error strings too.
  Role = Value['admin'] | Value['editor'] | Value['viewer']
  # email OR nil
  Contact = String[/@/] | Nil

  class Record < Data
    attribute :name, String.present # not a union: the baseline field
    attribute :age, Lax::Integer    # a union of coercions
    attribute :role, Role
    attribute :contact, Contact
  end
end

N = Integer(ENV.fetch('N', '2000'))

REGIMES = {
  'first-branch valid' => { name: 'Joe', age: 40,   role: 'admin',  contact: 'joe@example.com' },
  'union-hit valid'    => { name: 'Joe', age: '40', role: 'viewer', contact: nil },
  'fully invalid'      => { name: '',    age: 'xx', role: 'nope',   contact: 123 }
}.freeze

REPORTED_CLASSES = [
  'Plumb::Result::Valid',
  'Plumb::Result::Invalid',
  'String',
  'Array',
  'Hash'
].freeze

def run_regime(row)
  # warm (fill caches, JIT) and confirm validity classification
  valid = Bench::Record.resolve(row).valid?

  $invalid_allocs = 0
  report = MemoryProfiler.report { N.times { Bench::Record.resolve(row) } }
  invalid = $invalid_allocs

  by_class = report.allocated_objects_by_class.each_with_object(Hash.new(0)) do |h, acc|
    acc[h[:data]] = h[:count]
  end
  total = report.total_allocated

  { valid:, invalid:, by_class:, total: }
end

results = REGIMES.transform_values { |row| run_regime(row) }

puts "Parsing #{N} records per regime. Cells are total objects (per-record).\n\n"

LABEL_W = 20
COL_W = 22
cell   = ->(str) { str.to_s.rjust(COL_W) }
count  = ->(n) { cell.call(format('%d (%.2f)', n, n.to_f / N)) }

def rule(width) = puts('-' * width)

header = 'regime'.ljust(LABEL_W) + results.keys.map { |k| cell.call(k) }.join
puts header
puts 'valid output?'.ljust(LABEL_W) + results.values.map { |r| cell.call(r[:valid]) }.join
rule(header.size)

# Headline: throwaway Invalid objects (exact count via the constructor counter).
puts 'Result::Invalid'.ljust(LABEL_W) + results.values.map { |r| count.call(r[:invalid]) }.join

# Other tracked classes, from the sampling profiler.
REPORTED_CLASSES.each do |klass|
  next if klass == 'Plumb::Result::Invalid' # already shown (exact count)

  puts klass.sub('Plumb::', '').ljust(LABEL_W) +
       results.values.map { |r| count.call(r[:by_class][klass]) }.join
end

rule(header.size)
puts 'TOTAL objects'.ljust(LABEL_W) + results.values.map { |r| count.call(r[:total]) }.join

# Order sensitivity: the SAME union, matching the first vs the last branch.
puts "\nOrder sensitivity — (Value[a] | Value[b] | Value[c]).resolve(x), #{N}x each:"
[%w[admin first], %w[viewer last]].each do |value, position|
  $invalid_allocs = 0
  N.times { Bench::Role.resolve(value) }
  puts format('  match %-5s branch (%-6s): %d Invalid allocs (%.2f/record)',
              position, value, $invalid_allocs, $invalid_allocs.to_f / N)
end

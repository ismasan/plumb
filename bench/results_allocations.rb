# frozen_string_literal: true

# Surfaces the throwaway work Plumb does while parsing — Result objects, error
# strings and containers that are built and then discarded.
#
# The headline metric is INVALID TRANSITIONS: how many times a Result is flipped to
# invalid during a parse, including SUCCESSFUL ones. A value matching a non-first
# branch of a union (`A | B`, `Lax::*`, `nullable`, defaults, enums) pays for every
# branch it fell through, because `Or#call` tries each in turn and each miss runs,
# builds an error payload, and flips the cursor.
#
# This counts flips rather than `Result::Invalid` objects because there is no such
# class: Valid and Invalid were collapsed into one Result carrying a boolean, which
# is what lets the built-ins reuse the cursor in place (`#invalid!`) instead of
# allocating one per miss. That collapse removed the ALLOCATION but not the WORK,
# and the work is what this bench is about — so the flip is the honest successor to
# the old object count.
#
# The `Result` row is the other half of the picture, and shows the collapse paying
# off: it stays FLAT across all three regimes (4 per record) while the flips go
# 0 -> 5 -> 14. Misses cost work, but no longer cost an allocation.
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

# Count every flip to invalid, so the per-record figure is exact rather than
# sampled. Both forms are counted: #invalid allocates a fresh Result (the safe form
# user code uses), #invalid! flips the receiver (the built-ins' hot path).
$invalid_transitions = 0
module CountInvalidTransitions
  def invalid(*args, **kwargs)
    $invalid_transitions += 1
    super
  end

  def invalid!(*args, **kwargs)
    $invalid_transitions += 1
    super
  end
end
Plumb::Result.prepend(CountInvalidTransitions)

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

REPORTED_CLASSES = %w[
  Plumb::Result
  String
  Array
  Hash
].freeze

def run_regime(row)
  # warm (fill caches, JIT) and confirm validity classification
  valid = Bench::Record.resolve(row).valid?

  $invalid_transitions = 0
  report = MemoryProfiler.report { N.times { Bench::Record.resolve(row) } }
  invalid = $invalid_transitions

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

# Headline: flips to invalid (exact count, not sampled).
puts 'invalid flips'.ljust(LABEL_W) + results.values.map { |r| count.call(r[:invalid]) }.join

# Allocations, from the sampling profiler.
REPORTED_CLASSES.each do |klass|
  puts klass.sub('Plumb::', '').ljust(LABEL_W) +
       results.values.map { |r| count.call(r[:by_class][klass]) }.join
end

rule(header.size)
puts 'TOTAL objects'.ljust(LABEL_W) + results.values.map { |r| count.call(r[:total]) }.join

# Order sensitivity: the SAME union, matching the first vs the last branch.
puts "\nOrder sensitivity — (Value[a] | Value[b] | Value[c]).resolve(x), #{N}x each:"
[%w[admin first], %w[viewer last]].each do |value, position|
  $invalid_transitions = 0
  N.times { Bench::Role.resolve(value) }
  puts format('  match %-5s branch (%-6s): %d invalid flips (%.2f/record)',
              position, value, $invalid_transitions, $invalid_transitions.to_f / N)
end

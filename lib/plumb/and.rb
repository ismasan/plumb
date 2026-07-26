# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class And
    include Composable

    attr_reader :children, :input_type, :output_type

    # A refinement/sequencing join, built by `Composable#>>`. Both sides
    # validate the *same* value (no conversion), so an `And` is the
    # intersection of its children: the longer the chain, the narrower the
    # type. A value-converting step is a `Function` instead (see
    # lib/plumb/function.rb).
    #
    # #input_type / #output_type are the types the chain as a whole CONSUMES and
    # PRODUCES — not its two sides (those are `children`). They resolve through
    # the chain: `(String -> Integer) >> (Integer -> Integer)` consumes String
    # and produces Integer, not its left and right steps. Resolving one hop at
    # construction is enough — the children are already resolved by the same
    # rule, so this is O(1) per node — and doing it here (rather than through
    # Subtyping.resolved_*) keeps it off the memoization path entirely.
    def initialize(left, right)
      @left = left
      @right = right
      @input_type = left.input_type
      @output_type = right.output_type
      @children = [left, right].freeze
      freeze
    end

    private def _inspect
      %((#{@left.inspect} >> #{@right.inspect}))
    end

    def call(result)
      result.map(@left).map(@right)
    end

    # As a consumer a refinement accepts the constraint it actually passes — its
    # resolved output — not its #input_type, which is only the type the chain
    # opens with and would ignore the refinement (eg. `Integer[1..10].input_type`
    # is just Integer, but it only accepts values in 1..10).
    def accepted_type = Plumb::Subtyping.resolved_output(self)

    # A conjunction preserves the value only if BOTH steps do — a transform on
    # either side changes it. Recurses through the cached accessor so shared
    # subtrees are memoized once.
    def value_preserving? = children.all? { |c| Plumb::Subtyping.value_preserving?(c) }
  end
end

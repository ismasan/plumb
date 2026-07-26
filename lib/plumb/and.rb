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
      # A value-preserving right NARROWS what the left produces, it does not
      # replace it, so the chain produces the intersection of the two — eg.
      # `(String|Integer -> String).where(size: 10)` produces a String of size
      # 10, not the bare `(size === 10)`. A converting right replaces the value
      # outright, so its own output stands. A pure refinement (`String >> (size
      # === 10)`) already IS that intersection, so it is its own output type.
      @output_type = if Plumb::Subtyping.value_preserving?(right)
                       lo = left.output_type
                       lo.equal?(left) ? self : And.new(lo, right)
                     else
                       right.output_type
                     end
      @children = [left, right].freeze
      freeze
    end

    private def _inspect
      %((#{@left.inspect} >> #{@right.inspect}))
    end

    def call(result)
      result.map(@left).map(@right)
    end

    # As a consumer a refinement accepts the constraint it actually passes — the
    # right side's resolved output — not its #input_type, which is only the type
    # the chain opens with and would ignore the refinement (eg.
    # `Integer[1..10].input_type` is just Integer, but it only accepts values in
    # 1..10). Deliberately the RIGHT CHILD's output, not `#output_type`: that is
    # the whole intersection (including the left's own gate), and accepting
    # against it would make `#>>` stricter than it has ever been.
    def accepted_type = Plumb::Subtyping.resolved_output(children.last)

    # A conjunction preserves the value only if BOTH steps do — a transform on
    # either side changes it. Recurses through the cached accessor so shared
    # subtrees are memoized once.
    def value_preserving? = children.all? { |c| Plumb::Subtyping.value_preserving?(c) }
  end
end

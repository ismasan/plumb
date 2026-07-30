# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/conjunction'

module Plumb
  # THE LATTICE MEET — the greatest lower bound of two types. Built by `#>>`, `#/`,
  # `#where` and `#check` when neither side changes the value, and by `#&` when it
  # cannot narrow the operands into one node.
  #
  # Both sides validate the SAME value and return it untouched, so unlike {And} this
  # is not a pipeline between two types — it IS a type, describing the values that
  # satisfy both. The longer the chain, the narrower. Each side is a composed partial
  # identity: a check `A ⇀ A` narrowing the semantic type without touching the value.
  class Intersection
    include Composable
    include Conjunction

    def initialize(left, right)
      @left = left
      @right = right
      @input_type = left.input_type
      # A meet IS its own output type — nothing to resolve through. The whole
      # difference from And.
      @output_type = self
      @children = [left, right].freeze
      freeze
    end

    # An invariant, not a computation: Conjunction.build only produces an Intersection
    # when both sides preserve the value, so `is_a?(Intersection)` alone answers "is
    # this a pure refinement?" — which Optimizer.reduce_step relies on.
    def value_preserving? = true

    # A refinement accepts the constraint it actually passes — the right side's
    # resolved output — not its #input_type, which is only the type the chain opens
    # with and would ignore the refinement (`Integer[1..10].input_type` is just
    # Integer, but it accepts only 1..10). Deliberately the RIGHT CHILD's output and
    # not `#output_type`: that is the whole intersection including the left's gate,
    # and accepting against it would make `#>>` stricter than it has ever been.
    def accepted_type = Plumb::Subtyping.resolved_output(children.last)

    # node_name comes from Naming (:intersection). JSONSchemaVisitor handles it
    # separately from :and, merging both sides' specs unconditionally since both
    # describe one value.
  end
end

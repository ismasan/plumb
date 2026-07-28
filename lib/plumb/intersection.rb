# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/conjunction'

module Plumb
  # THE LATTICE MEET — the greatest lower bound of two types. Built by
  # `Composable#>>`, `#/`, `#where` and `#check` when neither side changes the
  # value, and by `#&` when it cannot narrow the two operands into one node.
  #
  # Both sides validate the SAME value and return it untouched, so unlike {And}
  # this is not a pipeline between two different types — it IS a type, describing
  # the values that satisfy both sides. The longer the chain, the narrower.
  #
  # In the plan's terms these are the composed partial identities: each side is a
  # check `A ⇀ A` that narrows the semantic type without touching the value, and
  # their composition narrows by both.
  class Intersection
    include Composable
    include Conjunction

    def initialize(left, right)
      @left = left
      @right = right
      @input_type = left.input_type
      # A meet IS its own output type: it describes the value that comes out.
      # There is nothing to resolve through, which is the whole difference from
      # And — and the reason the old shared node needed a conditional here.
      @output_type = self
      @children = [left, right].freeze
      freeze
    end

    # An invariant of the node, not a computation over its children: Conjunction.build
    # only produces an Intersection when both sides preserve the value. Callers
    # can therefore test `is_a?(Intersection)` where they used to test
    # `is_a?(And) && value_preserving?(node)` (see Optimizer.reduce_step).
    def value_preserving? = true

    # As a consumer, a refinement accepts the constraint it actually passes — the
    # right side's resolved output — not its #input_type, which is only the type
    # the chain opens with and would ignore the refinement (eg.
    # `Integer[1..10].input_type` is just Integer, but it only accepts values in
    # 1..10). Deliberately the RIGHT CHILD's output, not `#output_type`: that is
    # the whole intersection (including the left's own gate), and accepting
    # against it would make `#>>` stricter than it has ever been.
    def accepted_type = Plumb::Subtyping.resolved_output(children.last)

    # node_name comes from Naming (:intersection, derived from the class). The
    # JSON Schema and metadata visitors handle it separately from :and — see
    # JSONSchemaVisitor's :intersection handler, which merges both sides' specs
    # unconditionally because both describe one value.
  end
end

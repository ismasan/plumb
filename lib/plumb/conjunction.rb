# frozen_string_literal: true

module Plumb
  # The runtime shared by the two two-sided "both sides run" nodes: {Plumb::And}
  # (sequential composition) and {Plumb::Intersection} (the lattice meet). Both
  # execute as `left` then `right`; they differ ONLY in how types flow through
  # them, which is what each class defines.
  #
  # Splitting them is the point of this design. A single node serving both roles
  # cannot answer the type questions correctly, because the two roles disagree:
  #
  #   - a COMPOSITION is a morphism `source -> target`. It is identified for
  #     subtyping by what it PRODUCES, like a Function.
  #   - an INTERSECTION is a type. Both sides describe the SAME value, so it is
  #     identified by itself, and the subtype rule for it is the meet rule
  #     (`(a ∧ b) <= c` when either conjunct is).
  #
  # Applying the meet rule to a composition is unsound: it makes
  # `String >> (String -> Integer)` a subtype of String, even though the chain
  # produces an Integer — so the node lands under two disjoint types at once.
  #
  # Which of the two a given pair is is decided structurally, once, by
  # {Conjunction.build}: it is an Intersection exactly when neither side changes
  # the value. Callers that know which they mean may instantiate directly.
  module Conjunction
    # Build the right node for `left` then `right`.
    #
    # Both sides value-preserving => the pair is a refinement: each side narrows
    # the same value, order does not matter, and the result is a type
    # (Intersection). Otherwise some side converts, so the pair is a pipeline
    # whose ends differ (And).
    #
    # This is the single decision point — every construction site routes through
    # here rather than re-deriving the distinction from `#value_preserving?` at
    # use time, which is what the old shape had to do (see the deleted branch in
    # And#initialize and Optimizer.reduce_step).
    #
    # @param left [Composable]
    # @param right [Composable]
    # @return [Intersection, And]
    def self.build(left, right)
      if Plumb::Subtyping.value_preserving?(left) && Plumb::Subtyping.value_preserving?(right)
        Intersection.new(left, right)
      else
        And.new(left, right)
      end
    end

    attr_reader :children, :input_type, :output_type

    def call(result)
      result.map(@left).map(@right)
    end

    # Rebuild around new children. `self.class` keeps And vs Intersection — a
    # rewrite maps the sides, it does not reclassify the node.
    # @see Plumb::NodeMapper
    def with_children(children) = self.class.new(children[0], children[1])

    private def _inspect
      %((#{@left.inspect} >> #{@right.inspect}))
    end
  end
end

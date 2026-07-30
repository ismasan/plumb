# frozen_string_literal: true

module Plumb
  # The runtime shared by {Plumb::And} (sequential composition) and
  # {Plumb::Intersection} (the lattice meet). Both execute as `left` then `right`;
  # they differ only in how types flow, which each class defines.
  #
  # They must be separate nodes because the two roles disagree about identity: a
  # COMPOSITION is a morphism, identified by what it PRODUCES (like a Function),
  # while an INTERSECTION is a type, identified by itself and subject to the meet
  # rule (`(a ∧ b) <= c` when either conjunct is). Applying the meet rule to a
  # composition is unsound — it makes `String >> (String -> Integer)` a subtype of
  # String as well as Integer, two disjoint types.
  module Conjunction
    # An Intersection exactly when neither side changes the value (a refinement:
    # both sides narrow one value, order irrelevant); otherwise a pipeline whose
    # ends differ, an And.
    #
    # The single decision point — every construction site routes through here, so
    # the distinction is settled once rather than re-derived from
    # `#value_preserving?` at each use site.
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

    # Rebuilds by RECLASSIFYING: a rewrite that swaps a check for a conversion turns
    # a meet into a composition, and preserving the class would leave an Intersection
    # lying about #value_preserving?, which every reduction gates on.
    # @see Plumb::NodeMapper
    def with_children(children) = Conjunction.build(children[0], children[1])

    private def _inspect
      %((#{@left.inspect} >> #{@right.inspect}))
    end
  end
end

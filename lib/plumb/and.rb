# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/conjunction'

module Plumb
  # SEQUENTIAL COMPOSITION — a morphism `left.source -> right.target`, built by
  # `Composable#>>` when some side changes the value. The pure-refinement case
  # (neither side converts) is {Plumb::Intersection} instead; see
  # {Plumb::Conjunction} for why the two must be different nodes.
  #
  # #input_type / #output_type are the types the chain as a whole CONSUMES and
  # PRODUCES — not its two sides (those are `children`). They resolve through the
  # chain: `(String -> Integer) >> (Integer -> Integer)` consumes String and
  # produces Integer, not its left and right steps. Resolving one hop at
  # construction is enough — the children are already resolved by the same rule,
  # so this is O(1) per node — and doing it here (rather than through
  # Subtyping.resolved_*) keeps it off the memoization path entirely.
  class And
    include Composable
    include Conjunction

    def initialize(left, right)
      @left = left
      @right = right
      @input_type = left.input_type
      # A value-preserving right NARROWS what the left produces, it does not
      # replace it, so the chain produces the MEET of the two — eg.
      # `(String -> Integer)` followed by `where(size: 10)` produces an Integer of
      # size 10, not the bare `(size === 10)`. That meet is exactly an
      # Intersection, which is why this can now say so directly instead of
      # building a second And to stand in for it.
      #
      # A converting right replaces the value outright, so its own output stands.
      @output_type = if Plumb::Subtyping.value_preserving?(right)
                       Intersection.new(left.output_type, right)
                     else
                       right.output_type
                     end
      @children = [left, right].freeze
      freeze
    end

    # A composition is identified for subtyping by what it PRODUCES — the same
    # rule as Function and Implementation, and for the same reason: the input
    # constraints do not carry through to the output. This is what stops the meet
    # rule from being applied to a chain that converts. @see Composable#subtype_identity
    def subtype_identity = @output_type

    # Deliberately NO #accepted_type override. As the consumer of `left >> self`,
    # a composition accepts what it consumes — its #input_type, which is the
    # default. (The old shared node overrode this to the RIGHT child's output,
    # which is right for a refinement and wrong here: it would demand that the
    # upstream already produce what this chain's last step emits.) The refinement
    # behaviour now lives on Intersection, which is the node it was written for.
  end

  # The computation-AST name for this node. @see Plumb::Transform
  Compose = And
end

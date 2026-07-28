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
      # size 10, not the bare `(size === 10)`. A converting right replaces the
      # value outright, so its own output stands.
      #
      # Conjunction.build, not Intersection.new: a meet's `value_preserving?` is an
      # invariant, and `left.output_type` need not preserve values (a record's
      # output drops undeclared keys, a Static replaces the value), so only the
      # classifier may decide which node this is.
      #
      # The `lo.equal?(left)` guard is the fixpoint: a left that IS its own output
      # type would otherwise recurse building output types forever.
      @output_type = if Plumb::Subtyping.value_preserving?(right)
                       lo = left.output_type
                       lo.equal?(left) ? self : Conjunction.build(lo, right)
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

    # Deliberately NO #accepted_type override: as the consumer of `left >> self`, a
    # composition accepts what it consumes — its #input_type, which is the default.
    # Accepting against the RIGHT child's output instead (what Intersection does)
    # would demand that the upstream already produce what this chain's last step
    # emits.
  end
end

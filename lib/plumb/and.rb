# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/conjunction'

module Plumb
  # SEQUENTIAL COMPOSITION — a morphism `left.source -> right.target`, built by
  # `Composable#>>` when some side changes the value. The pure-refinement case
  # (neither side converts) is {Plumb::Intersection} instead; see
  # {Plumb::Conjunction} for why the two must be different nodes.
  #
  # #input_type / #output_type are what the chain as a whole CONSUMES and PRODUCES,
  # not its two sides (those are `children`): `(String -> Integer) >> (Integer ->
  # Integer)` consumes String and produces Integer. One hop at construction suffices,
  # since the children are already resolved by the same rule — O(1) per node, and off
  # the memoization path entirely.
  class And
    include Composable
    include Conjunction

    def initialize(left, right)
      @left = left
      @right = right
      @input_type = left.input_type
      # A value-preserving right NARROWS what the left produces rather than replacing
      # it, so the chain produces the MEET of the two: `(String -> Integer)` then
      # `where(size: 10)` produces an Integer of size 10, not the bare `(size === 10)`.
      # A converting right replaces the value, so its own output stands.
      #
      # Conjunction.build, not Intersection.new — `left.output_type` need not preserve
      # values (a record drops undeclared keys, a Static replaces it), and only the
      # classifier may decide. The `lo.equal?(left)` guard is the fixpoint: a left that
      # IS its own output type would otherwise recurse forever.
      @output_type = if Plumb::Subtyping.value_preserving?(right)
                       lo = left.output_type
                       lo.equal?(left) ? self : Conjunction.build(lo, right)
                     else
                       right.output_type
                     end
      @children = [left, right].freeze
      freeze
    end

    # Identified for subtyping by what it PRODUCES, like Function and Implementation:
    # the input constraints do not carry through. This is what stops the meet rule
    # reaching a chain that converts. @see Composable#subtype_identity
    def subtype_identity = @output_type

    # Deliberately NO #accepted_type override: a composition accepts what it consumes,
    # its #input_type, which is the default. Accepting against the right child's output
    # (what Intersection does) would demand the upstream already produce what this
    # chain's LAST step emits.

    # Fuse `self >> other` by RE-ASSOCIATING: `>>` is associative, so when the tail can
    # absorb `other` we rebuild around the fused tail. Without this, one non-fusable
    # step at the head blocks every later step from reducing — a pipeline behind a type
    # gate is `And(gate, step1)`, and only Function-to-Function fuses, so `step2`
    # onwards could never join.
    #
    # The soundness proof stays with the node that owns it: this only re-associates,
    # and `@right.fuse_with(other)` carries its own boundary check. Nil when the tail
    # declines. Recursion is bounded by the chain's depth.
    def fuse_with(other)
      fused = @right.fuse_with(other)
      fused && Conjunction.build(@left, fused)
    end

    # Boundary absorption re-associates for the same reason #fuse_with does: the
    # boundary a chain presents to a neighbour belongs to the step at that END of it,
    # so `And(gate, f) >> Types::Float` reaches `f`'s output slot, and `Types::Integer
    # >> And(f, x)` reaches `f`'s input slot. Nil when that end declines, and the
    # rebuilt half carries its own soundness proof. @see Composable#absorb_output
    def absorb_output(type)
      absorbed = @right.absorb_output(type)
      absorbed && Conjunction.build(@left, absorbed)
    end

    def absorb_input(type)
      absorbed = @left.absorb_input(type)
      absorbed && Conjunction.build(absorbed, @right)
    end
  end
end

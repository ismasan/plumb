# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/disjunction'

module Plumb
  # THE LATTICE JOIN — the least upper bound of two types, dual to
  # {Plumb::Intersection}. Built by `Composable#|` when every branch returns its
  # value untouched.
  #
  # Because no branch converts, the node describes exactly "a value in either
  # set" — it consumes and produces the same thing, so it IS its own input and
  # output type. That is the difference from {Plumb::Or}, whose ends differ.
  class Union
    include Composable
    include Disjunction

    def initialize(left, right)
      @left = Composable.wrap(left)
      @right = Composable.wrap(right)
      @children = [@left, @right].freeze
      freeze
    end

    # No branch converts, so the join describes exactly the values that come out
    # of it: it IS its own output type. No lazy rebuild, no identity guard, no
    # allocation — the mapping Or needs exists only because a converting branch
    # makes the two ends differ.
    #
    # #input_type is NOT symmetric with this and is inherited from Disjunction: a
    # branch may accept more than it describes (a bare-matcher Constraint accepts
    # Any), so the input side still has to map. See Disjunction#input_type.
    def output_type = self

    # An invariant of the node: Disjunction.build only produces a Union when every
    # branch preserves the value. @see Intersection#value_preserving?
    def value_preserving? = true

    # Visitors still dispatch on :or in this phase, so the JSON Schema and
    # metadata handlers (and Plumb.resolve_base_types) keep working untouched
    # while the node split lands. Phase 7 gives it its own node_name.
    def node_name = :or
  end

  # The type-AST name for the join, dual to {Plumb::Meet}.
  Join = Union
end

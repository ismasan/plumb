# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/disjunction'

module Plumb
  # THE LATTICE JOIN — the least upper bound of two types, dual to
  # {Plumb::Intersection}. Built by `#|` when every branch returns its value
  # untouched, so the node describes exactly "a value in either set" and is its own
  # output type. That is the difference from {Plumb::Or}, whose ends differ.
  class Union
    include Composable
    include Disjunction

    # No lazy rebuild, no identity guard, no allocation — the mapping Or needs exists
    # only because a converting branch makes its ends differ.
    #
    # NOT symmetric with #input_type, which is inherited from Disjunction: a branch may
    # accept more than it describes, so the input side still has to map.
    def output_type = self

    # An invariant of the node: Disjunction.build only produces a Union when every
    # branch preserves the value. @see Intersection#value_preserving?
    def value_preserving? = true

    # node_name comes from Naming (:union, derived from the class). The JSON
    # Schema visitor handles it separately from :or — a union is a plain anyOf,
    # with none of the default-value handling a choice needs.
  end
end

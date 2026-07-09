# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class AnyClass
    include Composable

    # These shortcuts bypass Composable's operators, but the wrap_left helpers
    # still consult the #to_plumb_type hook (an Encoder gets no orientation
    # context from the Any top and falls back to its default direction; a
    # Codec must not leak into the tree as a bare node).
    def |(other) = Or.wrap_left(other, left: self)
    def >>(other) = And.wrap_left(other, left: self)

    # Top is the identity of intersection: `Any & X == X`, mirroring `Any | X`.
    def &(other) = And.wrap_intersection(other, left: self)

    # Any.default(value) must trigger default when value is Undefined
    def default(...)
      Types::Undefined.not.default(...)
    end

    def call(result) = result

    # The identity type — accepts anything, changes nothing.
    def value_preserving? = true
  end
end

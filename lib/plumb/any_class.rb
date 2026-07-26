# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class AnyClass
    include Composable

    # These shortcuts bypass Composable's operators, but still resolve the
    # operand through the #to_plumb_type hook (an Encoder gets no orientation
    # context from the Any top and falls back to its default direction; a
    # Codec must not leak into the tree as a bare node).
    def |(other) = Composable.resolve_operand(other, op: :|, left: self)
    def >>(other) = Composable.resolve_operand(other, op: :>>, left: self)

    # Top is the identity of intersection: `Any & X == X`, mirroring `Any | X`.
    def &(other) = Composable.resolve_operand(other, op: :&, left: self)

    # Any.default(value) must trigger default when value is Undefined
    def default(...)
      Types::Undefined.not.default(...)
    end

    def call(result) = result

    # The identity type — accepts anything, changes nothing.
    def value_preserving? = true
  end
end

# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class AnyClass
    include Composable

    def |(other) = Composable.wrap(other)
    def >>(other) = Composable.wrap(other)

    # Top is the identity of intersection: `Any & X == X`, mirroring `Any | X`.
    def &(other) = Composable.wrap(other)

    # Any.default(value) must trigger default when value is Undefined
    def default(...)
      Types::Undefined.not.default(...)
    end

    def call(result) = result

    # The identity type — accepts anything, changes nothing.
    def value_preserving? = true
  end
end

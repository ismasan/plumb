# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class AnyClass
    include Composable

    def |(other) = Composable.wrap(other)
    def >>(other) = Composable.wrap(other)

    # Any.default(value) must trigger default when value is Undefined
    def default(...)
      Types::Undefined.not.default(...)
    end

    def call(result) = result
  end
end

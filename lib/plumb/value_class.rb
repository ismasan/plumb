# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class ValueClass
    include Composable

    attr_reader :value

    def initialize(value = Undefined)
      @value = value
      freeze
    end

    def [](value) = self.class.new(value)

    def call(result)
      @value == result.value ? result : result.invalid(errors: "Must be equal to #{@value}")
    end

    private

    def _inspect = @value.inspect
  end
end

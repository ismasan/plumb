# frozen_string_literal: true

require 'plumb/steppable'

module Plumb
  class ValueClass
    include Steppable

    attr_reader :value

    def initialize(value = Undefined)
      @value = value
    end

    def inspect = @value.inspect

    def [](value) = self.class.new(value)

    def call(result)
      @value == result.value ? result : result.invalid(errors: "Must be equal to #{@value}")
    end
  end
end

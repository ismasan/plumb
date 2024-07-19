# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class StaticClass
    include Composable

    attr_reader :value

    def initialize(value = Undefined)
      raise ArgumentError, 'value must be frozen' unless value.frozen?

      @value = value
      freeze
    end

    def [](value)
      self.class.new(value)
    end

    def call(result)
      result.valid(@value)
    end

    private

    def _inspect = @value.inspect
  end
end

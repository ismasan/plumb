# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class StaticClass
    include Composable

    attr_reader :children

    def initialize(value = Undefined)
      raise ArgumentError, 'value must be frozen' unless value.frozen?

      @value = value
      @children = [value].freeze
      freeze
    end

    def [](value)
      self.class.new(value)
    end

    # A static step ignores its input and always emits a fixed value. Its input
    # is therefore Any — it accepts anything, so it opts out of #>> checks on
    # the input side (eg. as the right of `Undefined >> Static[x]`). Its output
    # is the value itself (the default #output_type — this atomic node wraps
    # the value), so a successor that could never accept that value is caught
    # at composition time, eg. `Types::Static['foo'] >> Types::Integer` raises.
    def input_type = Types::Any

    def call(result)
      result.valid(@value)
    end

    private

    def _inspect = @value.inspect
  end
end

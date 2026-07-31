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

    # A static step is identified by the value it PRODUCES, so it is a subtype of
    # any type that value satisfies — which is what lets `Types::Integer.static(10)`
    # (ie. `Static[10] >> Types::Integer`) compose, while `Static['foo'] >>
    # Types::Integer` raises.
    #
    # Asked of the value itself rather than through Subtyping.atomic_subtype?,
    # because a literal MATCHER and a produced value are different things and each
    # reading is right for its own node. `Types::Value[5]` matches by `==` and so
    # describes every numeric spelling of 5 (hence Numeric, not Integer); the value
    # here is one concrete object, and `Static[10]` really does produce an Integer.
    def subtype_of?(other)
      return true if self == other
      return super if @value.is_a?(Composable)

      other === @value
    end

    def call(result)
      result.valid!(@value)
    end

    private

    def _inspect = @value.inspect
  end
end

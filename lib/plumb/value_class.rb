# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class ValueClass
    include Composable

    attr_reader :children

    def initialize(value = Undefined)
      @value = value
      # Pre-build the failure message once (the object is frozen and @value is
      # fixed), so a miss on the hot path — eg. every non-matching branch of a
      # `Value[a] | Value[b]` enum union — doesn't allocate a fresh String.
      # Frozen because it's shared across every failing call (and across threads
      # under Types::Array#concurrent) and only ever read, never mutated.
      @error = "Must be equal to #{value}".freeze
      @children = [value].freeze
      freeze
    end

    def [](value) = self.class.new(value)

    # A value constraint accepts any input and narrows it, so its input is Any
    # (opts out of #>> composition type-checks; the constraint refines, it does
    # not gate by Ruby type).
    def input_type = Types::Any

    # Matches a specific value and passes it through unchanged.
    def value_preserving? = true

    def call(result)
      @value == result.value ? result : result.invalid(errors: @error)
    end

    private

    def _inspect = @value.inspect
  end
end

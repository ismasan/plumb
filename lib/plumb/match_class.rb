# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class MatchClass
    include Composable

    attr_reader :children

    def initialize(matcher = Undefined, error: nil, label: nil)
      raise ParseError 'matcher must respond to #===' unless matcher.respond_to?(:===)

      @matcher = matcher
      @error = error.nil? ? build_error(matcher) : (error % matcher)
      @label = matcher.is_a?(Class) ? matcher.inspect : "Match(#{label || @matcher.inspect})"
      @children = [matcher].freeze
      freeze
    end

    def call(result)
      @matcher === result.value ? result : result.invalid(errors: @error)
    end

    private

    def _inspect = @label

    def build_error(matcher)
      case matcher
      when Class # A class primitive, ex. String, Integer, etc.
        "Must be a #{matcher}"
      when ::String, ::Symbol, ::Numeric, ::TrueClass, ::FalseClass, ::NilClass, ::Array, ::Hash
        "Must be equal to #{matcher}"
      when ::Range
        "Must be within #{matcher}"
      else
        "Must match #{matcher.inspect}"
      end
    end
  end
end

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

    # A Class/Module matcher is a nominal type gate, so it defines the input
    # type (itself). Any other matcher (regex/range/literal/proc) accepts any
    # input and merely narrows it, so it reports Any — opting out of #>>
    # composition type-checks (eg. so `String >> Match(/@/)` is allowed).
    def input_type = @matcher.is_a?(::Module) ? self : Types::Any

    # A matcher validates without changing the value, so `Match >> Match` (of
    # the same matcher) is redundant and `#>>` collapses it.
    def idempotent? = true

    # A proc matcher is a pure predicate (the `#check` mechanism): it asserts
    # something about the value without determining its type, so it is
    # transparent to type-flow — `Base.check { … }` still produces a Base.
    # Class/Range/Regexp/literal matchers DO carry type information (their output
    # is meaningful), so they are not transparent.
    def transparent? = @matcher.is_a?(::Proc)

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

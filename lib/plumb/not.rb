# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Not
    include Composable

    attr_reader :children, :errors

    # Double negation cancels: `Not(Not(X))` is just `X` — it accepts exactly
    # what `X` does. So wrapping an existing Not returns the inner type instead
    # of nesting (covering both `#not` and `Not[]`). A custom error message
    # keeps the Not, since collapsing would discard it.
    def self.new(step = nil, errors: nil)
      wrapped = Composable.wrap(step)
      return wrapped.children.first if errors.nil? && wrapped.is_a?(self)

      super
    end

    def initialize(step = nil, errors: nil)
      @step = Composable.wrap(step)
      @errors = errors || "must not be #{step.inspect}"
      # Store the *wrapped* step (as every container does), so `Not[String]` and
      # `Not[Types::String]` are the same node — and so the subtype engine isn't
      # fooled into treating a raw-class child as an atomic leaf.
      @children = [@step].freeze
      freeze
    end

    # @param step [Object]
    # @return [Not]
    def [](step)
      self.class.new(step)
    end

    private def _inspect
      %(Not(#{@step.inspect}))
    end

    def call(result)
      result = @step.call(result)
      result.valid? ? result.invalid(errors: @errors) : result.valid
    end
  end
end

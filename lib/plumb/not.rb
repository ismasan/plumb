# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Not
    include Composable

    attr_reader :children, :errors

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

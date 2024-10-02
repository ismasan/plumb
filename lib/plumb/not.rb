# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Not
    include Composable

    attr_reader :children, :errors

    def initialize(step, errors: nil)
      @step = Composable.wrap(step)
      @errors = errors || "must not be #{step.inspect}"
      @children = [step].freeze
      freeze
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

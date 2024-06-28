# frozen_string_literal: true

require 'plumb/steppable'

module Plumb
  class Not
    include Steppable

    attr_reader :step

    def initialize(step, errors: nil)
      @step = step
      @errors = errors
      freeze
    end

    private def _inspect
      %(Not(#{@step.inspect}))
    end

    def call(result)
      result = @step.call(result)
      result.success? ? result.halt(errors: @errors) : result.success
    end
  end
end

# frozen_string_literal: true

require 'plumb/steppable'

module Plumb
  class Policy
    include Steppable

    attr_reader :policy_name, :arg, :step

    def initialize(policy_name, arg, step)
      @policy_name = policy_name
      @arg = arg
      @step = step
      freeze
    end

    def call(result) = @step.call(result)
  end
end

# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  # Wrap a policy composition ("step") in a Policy object.
  # So that visitors such as JSONSchema and Metadata visitors
  # can define dedicated handlers for policies, if they need to.
  class Policy
    include Composable

    attr_reader :policy_name, :arg, :step, :children

    # @param policy_name [Symbol]
    # @param arg [Object, nil] the argument to the policy, if any.
    # @param step [Step] the step composition wrapped by this policy.
    def initialize(policy_name, arg, step)
      @policy_name = policy_name
      @arg = arg
      @step = step
      @children = [step].freeze
      freeze
    end

    # The standard Step interface.
    # @param result [Result::Valid]
    # @return [Result::Valid, Result::Invalid]
    def call(result) = @step.call(result)

    private def _inspect = @step.inspect
  end
end

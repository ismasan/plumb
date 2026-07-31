# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  # Wrap a policy composition ("step") in a Policy object.
  # So that visitors such as JSONSchema and Metadata visitors
  # can define dedicated handlers for policies, if they need to.
  class Policy
    include Composable

    attr_reader :policy_name, :arg, :children

    # @param policy_name [Symbol]
    # @param arg [Object, nil] the argument to the policy, if any.
    # @param step [Step] the step composition wrapped by this policy.
    # @see Plumb::NodeMapper
    def with_children(children) = self.class.new(policy_name, arg, children.first)

    def initialize(policy_name, arg, step)
      @policy_name = policy_name
      @arg = arg
      @step = step
      @children = [step].freeze
      freeze
    end

    # A Policy is identified by its name, its argument AND the step it wraps. The
    # step is load-bearing: `String.present` and `Integer.present` share a name and
    # argument while accepting disjoint values, and `subtype?` short-circuits on
    # `==` before the #identity_wrapper? guard that keeps a wrapper from being
    # dropped — so without the step, `|` would absorb one into the other.
    def ==(other)
      other.instance_of?(self.class) &&
        policy_name == other.policy_name &&
        arg == other.arg &&
        children == other.children
    end

    # A Policy is a transparent wrapper: it delegates type-flow to the wrapped
    # step.
    def input_type = @step.input_type
    def output_type = @step.output_type

    # The standard Step interface.
    # @param result [Result]
    # @return [Result]
    def call(result) = @step.call(result)

    private def _inspect = @step.inspect
  end
end

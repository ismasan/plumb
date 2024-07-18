# frozen_string_literal: true

require 'plumb/policies'

module Plumb
  @policies = Policies.new

  def self.policies
    @policies
  end

  # Register a policy with the given name and block.
  # Optionally define a method on the Steppable method to call the policy.
  # Example:
  #   Plumb.policy(:multiply_by, for_type: Integer, helper: true) do |step, factor, &block|
  #     step.transform(Integer) { |number| number * factor }
  #   end
  #
  #  type = Types::Integer.multiply_by(2)
  #  type.parse(10) # => 20
  #
  # @param name [Symbol] the name of the policy
  # @param opts [Hash] options for the policy
  # @yield [Step, Object, &block] the step (type), policy argument, and policy block, if any.
  def self.policy(name, opts = {}, &block)
    name = name.to_sym
    if opts.is_a?(Hash) && block_given?
      for_type = opts[:for_type] || Object
      helper = opts[:helper] || false
    elsif opts.respond_to?(:call) && opts.respond_to?(:for_type) && opts.respond_to?(:helper)
      for_type = opts.for_type
      helper = opts.helper
      block = opts.method(:call)
    else
      raise ArgumentError, 'Expected a block or a hash with :for_type and :helper keys'
    end

    policies.register(for_type, name, block)

    return self unless helper

    if Steppable.instance_methods.include?(name)
      raise Policies::MethodAlreadyDefinedError, "Method #{name} is already defined on Steppable"
    end

    Steppable.define_method(name) do |arg = Undefined, &bl|
      if arg == Undefined
        policy(name, &bl)
      else
        policy(name, arg, &bl)
      end
    end

    self
  end
end

require 'plumb/result'
require 'plumb/type_registry'
require 'plumb/steppable'
require 'plumb/any_class'
require 'plumb/step'
require 'plumb/and'
require 'plumb/pipeline'
require 'plumb/static_class'
require 'plumb/value_class'
require 'plumb/match_class'
require 'plumb/not'
require 'plumb/or'
require 'plumb/tuple_class'
require 'plumb/array_class'
require 'plumb/stream_class'
require 'plumb/hash_class'
require 'plumb/interface_class'
require 'plumb/types'
require 'plumb/json_schema_visitor'
require 'plumb/schema'

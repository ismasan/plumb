# frozen_string_literal: true

require 'plumb/policies'

module Plumb
  # A policy registry for Plumb
  # It holds and gets registered policies.
  # Policies are callable objects that act as factories for type compositions.
  class Policies
    UnknownPolicyError = Class.new(StandardError)
    MethodAlreadyDefinedError = Class.new(StandardError)

    def initialize
      @policies = {}
    end

    # Register a policy for all or specific outpyt types.
    # Example for a policy that works for all types:
    #   #register(Object, :my_policy, ->(node, arg) { ... })
    # Example for a policy that works for a specific type:
    #   #register(String, :my_policy, ->(node, arg) { ... })
    # Example for a policy that works for a specific interface:
    #   #register(:size, :my_policy, ->(node, arg) { ... })
    #
    # The policy callable takes the step it is applied to, a policy argument (if any) and a policy block (if any).
    # Example for a policy #default(default_value = Undefined) { 'some-default-value' }
    #   policy = proc do |type, default_value = Undefined, &block|
    #     type | (Plumb::Types::Undefined >> Plumb::Types::Static[default_value])
    #   end
    #
    # @param for_type [Class, Symbol] the type the policy is for.
    # @param name [Symbol] the name of the policy.
    # @param policy [Proc] the policy to register.
    def register(for_type, name, policy)
      @policies[name] ||= {}
      @policies[name][for_type] = policy
    end

    # Get a policy for a given type.
    # @param types [Array<Class>] the types
    # @param name [Symbol] the policy name
    # @return [#call] the policy callable
    # @raise [UnknownPolicyError] if the policy is not registered for the given types
    def get(types, name)
      if (pol = resolve_shared_policy(types, name))
        pol
      elsif (pol = @policies.dig(name, Object))
        raise UnknownPolicyError, "Unknown policy #{name} for #{types.inspect}" unless pol

        pol
      else
        raise UnknownPolicyError, "Unknown or incompatible policy #{name} for #{types.inspect}"
      end
    end

    private

    def resolve_shared_policy(types, name)
      pols = types.map do |type|
        resolve_policy(type, name)
      end.uniq
      pols.size == 1 ? pols.first : nil
    end

    def resolve_policy(type, name)
      policies = @policies[name]
      return nil unless policies

      # { Object => policy1, String => policy2, size: policy3 }
      #
      policies.find do |for_type, _pol|
        case for_type
        when Symbol # :size
          type.instance_methods.include?(for_type)
        when Class # String
          for_type == type
        end
      end&.last
    end
  end
end

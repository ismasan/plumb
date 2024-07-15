# frozen_string_literal: true

require 'plumb/policies'

module Plumb
  class Policies
    UnknownPolicyError = Class.new(StandardError)
    DifferingTypesError = Class.new(StandardError)
    MethodAlreadyDefinedError = Class.new(StandardError)

    def initialize
      @policies = {}
    end

    def register(for_type, name, policy)
      @policies[for_type] ||= {}
      @policies[for_type][name] = policy
    end

    def get(types, name)
      raise DifferingTypesError, "Can't apply policy to type with differing types (#{types.inspect})" if types.size > 1

      pol = @policies.dig(types.first, name) || @policies.dig(Object, name)
      raise UnknownPolicyError, "Unknown policy #{name} for #{types.first.inspect}" unless pol

      pol
    end
  end
end

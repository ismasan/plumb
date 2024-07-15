# frozen_string_literal: true

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

  @policies = Policies.new

  def self.policies
    @policies
  end

  def self.policy(name, helper: false, for_type: Object, &block)
    name = name.to_sym
    policies.register(for_type, name, block)

    return self unless helper

    if Steppable.instance_methods.include?(name)
      raise Policies::MethodAlreadyDefinedError, "Method #{name} is already defined on Steppable"
    end

    Steppable.define_method(name) do |*args|
      policy(name, *args)
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

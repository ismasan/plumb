# frozen_string_literal: true

require 'plumb/policies'

module Plumb
  class Policies
    UnknownPolicyError = Class.new(StandardError)
    MethodAlreadyDefinedError = Class.new(StandardError)

    def initialize
      @policies = {}
    end

    def register(for_type, name, policy)
      @policies[name] ||= {}
      @policies[name][for_type] = policy
    end

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

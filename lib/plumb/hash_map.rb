# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class HashMap
    include Composable

    attr_reader :children

    def initialize(key_type, value_type)
      @key_type = key_type
      @value_type = value_type
      @children = [key_type, value_type].freeze
      freeze
    end

    # A HashMap is a Hash, so it is a subtype of the "any Hash" top — an
    # empty-schema HashClass like Types::Hash. It is NOT a subtype of a
    # structured HashClass, which requires specific keys a map doesn't
    # guarantee. Against another HashMap it is covariant in key and value types
    # (handled by the default #subtype_of?).
    def subtype_of?(other)
      return other._schema.empty? if other.is_a?(HashClass)

      super
    end

    def call(result)
      return result.invalid(errors: 'must be a Hash') unless result.value.is_a?(::Hash)

      errors = {}

      parsed = result.value.each.with_object({}) do |(key, value), memo|
        key_r = @key_type.resolve(key)
        value_r = @value_type.resolve(value)
        errs = []
        errs << "key #{key_r.errors}" unless key_r.valid?
        errs << "value #{value_r.value.inspect} #{value_r.errors}" unless value_r.valid?
        errors[key] = errs unless errs.empty?
        memo[key_r.value] = value_r.value
      end

      errors.empty? ? result.valid(parsed) : result.invalid(errors:)
    end

    def filtered
      FilteredHashMap.new(@key_type, @value_type)
    end

    private def _inspect = "HashMap[#{@key_type.inspect}, #{@value_type.inspect}]"

    # Same key/value types as a HashMap (so it inherits #initialize, #children
    # and the hash-family #subtype_of?), but filters out invalid entries instead
    # of rejecting the whole Hash.
    class FilteredHashMap < HashMap
      # Naming derives #node_name when Composable is *included* (on HashMap), so
      # the subclass would otherwise inherit :hash_map. Restore its own name so
      # visitors still dispatch to their :filtered_hash_map handlers.
      def node_name = :filtered_hash_map

      def call(result)
        result.invalid(errors: 'must be a Hash') unless result.value.is_a?(::Hash)

        hash = result.value.each.with_object({}) do |(key, value), memo|
          key_r = @key_type.resolve(key)
          value_r = @value_type.resolve(value)
          memo[key_r.value] = value_r.value if key_r.valid? && value_r.valid?
        end

        result.valid(hash)
      end

      private def _inspect = "HashMap[#{@key_type.inspect}, #{@value_type.inspect}].filtered"
    end
  end
end

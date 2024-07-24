# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class HashMap
    include Composable

    attr_reader :key_type, :value_type, :children

    def initialize(key_type, value_type)
      @key_type = key_type
      @value_type = value_type
      @children = [key_type, value_type].freeze
      freeze
    end

    def call(result)
      return result.invalid(errors: 'must be a Hash') unless result.value.is_a?(::Hash)

      failed = result.value.lazy.filter_map do |key, value|
        key_r = @key_type.resolve(key)
        value_r = @value_type.resolve(value)
        if !key_r.valid?
          [:key, key, key_r]
        elsif !value_r.valid?
          [:value, value, value_r]
        end
      end
      if (first = failed.next)
        field, val, halt = failed.first
        result.invalid(errors: "#{field} #{val.inspect} #{halt.errors}")
      end
    rescue StopIteration
      result
    end

    def filtered
      FilteredHashMap.new(key_type, value_type)
    end

    private def _inspect = "HashMap[#{@key_type.inspect}, #{@value_type.inspect}]"

    class FilteredHashMap
      include Composable

      attr_reader :key_type, :value_type, :children

      def initialize(key_type, value_type)
        @key_type = key_type
        @value_type = value_type
        @children = [key_type, value_type].freeze
        freeze
      end

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

# frozen_string_literal: true

require 'plumb/steppable'

module Plumb
  class TaggedHash
    include Steppable

    attr_reader :key, :types

    def initialize(hash_type, key, types)
      @hash_type = hash_type
      @key = Key.wrap(key)
      @types = types

      raise ArgumentError, 'all types must be HashClass' if @types.size == 0 || @types.any? do |t|
        !t.is_a?(HashClass)
      end
      raise ArgumentError, "all types must define key #{@key}" unless @types.all? { |t| !!t.at_key(@key) }

      # types are assumed to have static values for the index field :key
      @index = @types.each.with_object({}) do |t, memo|
        memo[t.at_key(@key).resolve.value] = t
      end

      freeze
    end

    def call(result)
      result = @hash_type.call(result)
      return result unless result.valid?

      child = @index[result.value[@key.to_sym]]
      return result.invalid(errors: "expected :#{@key.to_sym} to be one of #{@index.keys.join(', ')}") unless child

      child.call(result)
    end

    private

    def _inspect = "TaggedHash[#{@key.inspect}, #{@types.map(&:inspect).join(', ')}]"
  end
end

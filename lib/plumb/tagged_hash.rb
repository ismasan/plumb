# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class TaggedHash
    include Composable

    attr_reader :key, :children

    def initialize(hash_type, key, children)
      @hash_type = hash_type
      @key = Key.wrap(key)
      @children = children

      raise ArgumentError, 'all types must be HashClass' if @children.size.zero? || @children.any? do |t|
        !t.is_a?(HashClass)
      end
      raise ArgumentError, "all types must define key #{@key}" unless @children.all? { |t| !!t.at_key(@key) }

      # types are assumed to have literal values for the index field :key
      @index = @children.each.with_object({}) do |t, memo|
        key_type = t.at_key(@key)
        raise ParseError, "key type at :#{@key} #{key_type} must be a Match type" unless key_type.is_a?(MatchClass)

        memo[key_type.children[0]] = t
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

    def _inspect = "TaggedHash[#{@key.inspect}, #{@children.map(&:inspect).join(', ')}]"
  end
end

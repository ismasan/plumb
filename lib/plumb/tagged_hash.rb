# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class TaggedHash
    include Composable

    attr_reader :key, :children, :hash_type

    # @see Plumb::NodeMapper
    def with_children(children) = self.class.new(hash_type, key, children)

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
        raise ParseError, "key type at :#{@key} #{key_type} must be a Constraint" unless key_type.is_a?(Constraint)

        memo[key_type.children[0]] = t
      end

      freeze
    end

    # As a consumer, relax each variant's fields to what they accept (like
    # HashClass#accepted_type) — but keep the discriminator field literal, so
    # the rebuilt TaggedHash still satisfies its "tag key is a Constraint"
    # invariant. Lets `Type >> Codec` (which builds a rewritten variant with a
    # converting field) type-check against the output tagged hash.
    def accepted_type
      relaxed = @children.map do |child|
        schema = child._schema.each_with_object({}) do |(k, field), h|
          h[k] = k.eql?(@key) ? field : Plumb::Subtyping.accepted_type(field)
        end
        child.class.new(schema:)
      end
      self.class.new(@hash_type, @key, relaxed)
    end

    def call(result)
      result = @hash_type.call(result)
      return result unless result.valid?

      child = @index[result.value[@key.to_sym]]
      return result.invalid!(errors: "expected :#{@key.to_sym} to be one of #{@index.keys.join(', ')}") unless child

      child.call(result)
    end

    private

    def _inspect = "TaggedHash[#{@key.inspect}, #{@children.map(&:inspect).join(', ')}]"
  end
end

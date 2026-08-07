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
        # Accept either bare or base-constrained single-value tags.
        tag = Plumb::Subtyping.literal_value(key_type)
        if Undefined.equal?(tag)
          raise ParseError, "key type at :#{@key} #{key_type} must match a single literal value"
        end

        memo[tag] = t
      end

      freeze
    end

    # Equality includes the discriminator and base hash because #children contains
    # only variants; comparing children alone would conflate distinct tagged hashes.
    # @param other [Object]
    # @return [Boolean]
    def ==(other)
      other.instance_of?(self.class) &&
        key.eql?(other.key) &&
        hash_type == other.hash_type &&
        children == other.children
    end

    # A tagged hash is a subtype when every selectable variant is a subtype. The
    # base hash only narrows those variants, so ignoring it here is conservative;
    # comparing variants pairwise would be unsound across different discriminators.
    # @param other [Composable]
    # @return [Boolean]
    def subtype_of?(other)
      return true if self == other

      @children.all? { |variant| Plumb::Subtyping.subtype?(variant, other) }
    end

    # Relaxes each variant's non-discriminator fields to their accepted types.
    # @return [TaggedHash]
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

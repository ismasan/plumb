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
        # What a discriminator needs is the literal it matches, whichever node
        # carries it — a bare literal is a ValueClass, one narrowed by a base
        # (`Types::String['event']`) is a Constraint. Subtyping.literal_value reads
        # both and returns Undefined for anything matching more than one value.
        tag = Plumb::Subtyping.literal_value(key_type)
        if Undefined.equal?(tag)
          raise ParseError, "key type at :#{@key} #{key_type} must match a single literal value"
        end

        memo[tag] = t
      end

      freeze
    end

    # As a consumer, relax each variant's fields to what they accept (like
    # HashClass#accepted_type) — but keep the discriminator field literal, so
    # the rebuilt TaggedHash still satisfies its "tag key is a Constraint"
    # invariant. Lets `Type >> Codec` (which builds a rewritten variant with a
    # converting field) type-check against the output tagged hash.
    # Identified by the discriminator key and the Hash it narrows as well as by its
    # variants. #children holds only the variants, so a structural comparison would
    # find two TaggedHashes equal while they were keyed on different fields, or
    # narrowing different base Hashes — and `==` is what
    # Plumb::Subtyping.subtype? consults first, so that would make them mutual
    # subtypes. `Key#eql?` is the key comparison (Key defines no #==) and
    # deliberately ignores optionality, which a discriminator never uses.
    def ==(other)
      other.instance_of?(self.class) &&
        key.eql?(other.key) &&
        hash_type == other.hash_type &&
        children == other.children
    end

    # A TaggedHash resolves to ONE of its variants: #call runs @hash_type and then
    # the variant selected by the discriminator, so the value it returns is
    # whatever that variant produced. It is therefore a subtype of anything EVERY
    # variant is a subtype of — which makes it a subtype of the "any Hash" top,
    # like the rest of the Hash family.
    #
    # Deliberately conservative: it ignores that @hash_type also had to pass, which
    # can only make the real value set narrower, never wider. Without this the
    # default covariant rule would compare variant lists alone and call two
    # TaggedHashes over different base Hashes mutual subtypes.
    def subtype_of?(other)
      return true if self == other

      @children.all? { |variant| Plumb::Subtyping.subtype?(variant, other) }
    end

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

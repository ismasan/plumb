# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  # A hash-schema key. Two flavours:
  #
  #   * a LITERAL key — a Symbol or String name (`name:`, `'name' =>`). It is
  #     matched by exact lookup and carries `#to_key`/`#to_sym`. A trailing `?`
  #     (`name?:`) marks it optional. This is the common case and behaves exactly
  #     as before.
  #   * a MATCHER key — any Plumb type / `#===` object used as a key
  #     (`Types::String[/^id_/] => ...`, or the `_` catch-all which wraps
  #     `Types::Any`). It matches other keys via `matcher === other_key`, has no
  #     single `#to_key`, and is inherently optional (it imposes no specific
  #     required key).
  class Key
    # OPTIONAL_EXP = /(\w+)(\?)?$/
    OPTIONAL_EXP = /(?<word>[A-Za-z0-9_$]+)(?<qmark>\?)?/

    def self.wrap(key, symbolize: false)
      key.is_a?(Key) ? key : new(key, symbolize:)
    end

    attr_reader :to_key, :to_sym, :node_name, :matcher

    def initialize(key, optional: false, symbolize: false)
      @node_name = :key
      if key.is_a?(::Symbol) || key.is_a?(::String)
        key_type = symbolize ? Symbol : key.class
        match = OPTIONAL_EXP.match(key.to_s)
        name = match[:word]
        @to_key = key_type == Symbol ? name.to_sym : name
        @to_sym = @to_key.to_sym
        @optional = !match[:qmark].nil? ? true : optional
        @matcher = @to_key
        @literal = true
      else
        # A type/matcher key. It matches other keys structurally, so it has no
        # concrete #to_key and never imposes a required key.
        @matcher = Composable.wrap(key)
        @to_key = nil
        @to_sym = nil
        @optional = true
        @literal = false
      end
      freeze
    end

    # A concrete Symbol/String key (exact lookup) vs a type/matcher key.
    def literal? = @literal

    # The `_` catch-all: a matcher key over the Any top, so it matches every key.
    def catch_all? = !@literal && @matcher.is_a?(AnyClass)

    # Does this key match `other` (a raw hash key)? Literal keys match by `==`
    # (`Symbol#===`/`String#===`); matcher keys by `matcher === other`.
    def match?(other) = @matcher === other

    def to_s = (@to_key || @matcher).to_s

    # Dedupe/lookup identity. Literal keys hash by name (unchanged); matcher keys
    # hash by matcher class (structural equality disambiguates via #eql?), so two
    # `_` catch-alls collapse. Two keys are eql? when both literal with the same
    # name, or both matchers with equal matchers — optionality is deliberately
    # ignored (so `name?`/`name` collapse), and HashClass#== compares it separately.
    def hash = @literal ? @to_key.hash : @matcher.class.hash

    def eql?(other)
      return false unless other.is_a?(Key)

      if @literal
        other.literal? && @to_key == other.to_key
      else
        !other.literal? && @matcher == other.matcher
      end
    end

    def optional?
      @optional
    end

    def inspect
      if @literal
        "#{@to_key}#{'?' if @optional}"
      elsif catch_all?
        '_'
      else
        @matcher.inspect
      end
    end
  end
end

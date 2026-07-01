# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class MatchClass
    include Composable

    attr_reader :children, :base, :matcher

    # @param matcher [#===] the value/type/predicate to match against
    # @param base [Composable, nil] the type this matcher *refines*. `nil` for a
    #   root type matcher (eg. `Types::Integer` is `Match(::Integer)`); set for a
    #   refinement built via `#[]`/`#match`/`#check` (eg. `Integer[1..10]` is
    #   `Match(1..10, base: Types::Integer)`). Carrying the base lets a matcher
    #   answer subtyping locally — it is a subtype of whatever its base is — so no
    #   `And` wrapper (or transparency flag) is needed to preserve the base type.
    def initialize(matcher = Undefined, base: nil, error: nil, label: nil)
      raise ParseError, 'matcher must respond to #===' unless matcher.respond_to?(:===)

      raise_if_incompatible!(base, matcher) if base

      @matcher = matcher
      @base = base
      @error = error.nil? ? build_error(matcher) : (error % matcher)
      @label = matcher.is_a?(Class) ? matcher.inspect : "Match(#{label || @matcher.inspect})"
      @children = [matcher].freeze
      freeze
    end

    # As the consumer of a `left >> self` chain:
    #   - a refinement (has a base) or a Class/Module gate accepts exactly what it
    #     validates — itself — so `Integer >> Integer[1..10]` is correctly
    #     rejected (narrow with `#[]` instead), and the default `#accepted_type`
    #     (its resolved input) is `self`;
    #   - a bare non-Module matcher (regex/range/literal/proc with no base) merely
    #     narrows arbitrary input, so it reports Any and opts out of the check.
    def input_type = base || @matcher.is_a?(::Module) ? self : Types::Any

    # A matcher validates without changing the value, so `Match >> Match` (of the
    # same matcher) is redundant and `#>>` collapses it.
    def idempotent? = true

    # Structural subtyping. A matcher describes the set `base ∩ {x | matcher === x}`
    # (base = everything when nil). `self <= other` when self's set is contained in
    # each of other's conjuncts: within other's base (if any) AND within other's
    # matcher. Against a non-matcher type, a refinement is a subtype of whatever
    # its base is (like AttributeValueMatch).
    def subtype_of?(other)
      return true if self == other

      if other.is_a?(MatchClass)
        within_base = other.base.nil? || Plumb::Subtyping.subtype?(self, other.base)
        within_base && within_matcher?(other.matcher)
      elsif base
        Plumb::Subtyping.subtype?(base, other)
      else
        false
      end
    end

    # Is every value self describes matched by `m`? True if self's own matcher is
    # within `m`, or self's base already guarantees it (eg. `Integer.check {}` is
    # within `::Integer` because its base is Integer, even though its proc matcher
    # tells us nothing).
    protected def within_matcher?(m)
      Plumb::Subtyping.atomic_subtype?(matcher, m) ||
        (base.is_a?(MatchClass) && base.within_matcher?(m))
    end

    # Two matchers are equal when they match the same thing over the same base.
    def ==(other)
      other.is_a?(self.class) && other.matcher == matcher && other.base == base
    end

    def call(result)
      result = base.call(result) if base
      return result unless result.valid?

      @matcher === result.value ? result : result.invalid(errors: @error)
    end

    private

    # A refinement whose matcher can never match a value of the base is a
    # contradiction — an empty type, almost always a mistake — so reject it at
    # build time (eg. `Types::String[1..20]`: no String is in an integer range).
    # Only checked for matchers whose domain is knowable (Class/Range/Regexp/
    # primitive literal); procs and custom `#===` objects are opaque, so allowed.
    def raise_if_incompatible!(base, matcher)
      base_types = Plumb.resolve_base_types(base)
      return if base_types.empty? # unknown base (eg. a Data schema) — allow
      return if base_types.any? { |klass| matcher_may_match?(matcher, klass) }

      raise Plumb::TypeError,
            "cannot refine #{base.inspect} with #{matcher.inspect}: " \
            "no #{base_types.map(&:inspect).join(' / ')} value can match it"
    end

    # Could `matcher` match at least one instance of `klass`?
    def matcher_may_match?(matcher, klass)
      case matcher
      when ::Module then !!((matcher <= klass) || (klass <= matcher))
      when ::Range then (e = matcher.begin || matcher.end).nil? || e.is_a?(klass)
      when ::Regexp then klass <= ::String || klass <= ::Symbol
      when ::String, ::Symbol, ::Numeric, ::TrueClass, ::FalseClass, ::NilClass
        matcher.is_a?(klass)
      else
        true # proc / opaque `#===` object: domain unknown, allow
      end
    end

    def _inspect
      return @label unless base

      "#{base.inspect}[#{@matcher.inspect}]"
    end

    def build_error(matcher)
      case matcher
      when Class # A class primitive, ex. String, Integer, etc.
        "Must be a #{matcher}"
      when ::String, ::Symbol, ::Numeric, ::TrueClass, ::FalseClass, ::NilClass, ::Array, ::Hash
        "Must be equal to #{matcher}"
      when ::Range
        "Must be within #{matcher}"
      else
        "Must match #{matcher.inspect}"
      end
    end
  end
end

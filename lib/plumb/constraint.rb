# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Constraint
    include Composable

    attr_reader :children, :base, :matcher

    # @param matcher [#===] the value/type/predicate to match against
    # @param base [Composable, nil] the type this matcher *refines*. `nil` for a
    #   root type matcher (eg. `Types::Integer` is `Constraint(::Integer)`); set for a
    #   refinement built via `#[]`/`#match`/`#check` (eg. `Integer[1..10]` is
    #   `Constraint(1..10, base: Types::Integer)`). Carrying the base lets a matcher
    #   answer subtyping locally — it is a subtype of whatever its base is — so no
    #   `And` wrapper (or transparency flag) is needed to preserve the base type.
    def initialize(matcher = Undefined, base: nil, error: nil, label: nil)
      raise ParseError, 'matcher must respond to #===' unless matcher.respond_to?(:===)

      raise_if_incompatible!(base, matcher) if base

      @matcher = matcher
      @base = base
      @error = error.nil? ? build_error(matcher) : (error % matcher)
      @label = matcher.is_a?(Class) ? matcher.inspect : "Constraint(#{label || @matcher.inspect})"
      @children = [matcher].freeze
      freeze
    end

    # Smart refinement constructor: builds `Constraint.new(matcher, base:)`, but
    # when both `base` (a Constraint) and `matcher` describe Ranges, it INTERSECTS
    # them into a single Range over `base`'s own base rather than stacking two
    # range checks — so `Integer[0..100][10..]` is `Integer[10..100]`, and
    # `Integer[0..100] >> Integer[0..]` reduces to `Integer[0..100]`. Only Ranges
    # (a knowable, totally-ordered matcher) merge; other matchers stack as before.
    # An empty intersection can't be represented as a Range, so it falls back to
    # stacking (the type still rejects every value at runtime).
    def self.narrow(base, matcher)
      if base.is_a?(Constraint) && base.matcher.is_a?(::Range) && matcher.is_a?(::Range)
        merged = intersect_ranges(base.matcher, matcher)
        return narrow(base.base, merged) if merged # recurse: base.base may be a type gate
      end
      new(matcher, base:)
    end

    # Intersection of two Ranges as a Range, or nil when empty / incomputable
    # (incomparable endpoints — left to #new's incompatibility check to reject).
    def self.intersect_ranges(a, b)
      ab = a.begin
      bb = b.begin
      new_begin = ab.nil? ? bb : (bb.nil? ? ab : (ab >= bb ? ab : bb)) # greater begin (nil = -inf)
      ae = a.end
      be = b.end
      new_end, new_exclude = # lesser end (nil = +inf), carrying exclusivity
        if ae.nil? then [be, b.exclude_end?]
        elsif be.nil? then [ae, a.exclude_end?]
        elsif ae < be then [ae, a.exclude_end?]
        elsif be < ae then [be, b.exclude_end?]
        else [ae, a.exclude_end? || b.exclude_end?]
        end
      unless new_begin.nil? || new_end.nil?
        return nil if new_begin > new_end
        return nil if new_begin == new_end && new_exclude
      end
      ::Range.new(new_begin, new_end, new_exclude)
    rescue ::ArgumentError, ::TypeError
      nil
    end
    private_class_method :intersect_ranges

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

      if other.is_a?(Constraint)
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
        (base.is_a?(Constraint) && base.within_matcher?(m))
    end

    # Two matchers are equal when they match the same thing over the same base.
    def ==(other)
      other.is_a?(self.class) && other.matcher == matcher && other.base == base
    end

    def call(result)
      # Only the base can invalidate the incoming result (callers — map/Or/resolve
      # — always pass a valid one), so the `valid?` short-circuit is only needed
      # when there IS a base. Root constraints skip straight to the matcher check,
      # like a flat leaf. Reading @base directly (not the #base reader) also skips
      # a dispatch on this hot path.
      if @base
        result = @base.call(result)
        return result unless result.valid?
      end

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

# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Constraint
    include Composable

    # Sentinel returned by `merge_matchers`/`intersect_ranges` when two same-kind
    # matchers have a PROVABLY-EMPTY overlap (disjoint Ranges, empty Set
    # intersection). Distinct from `nil`, which means "not the same knowable kind,
    # or an incomputable overlap — leave the two matchers stacked". Callers map
    # EMPTY to `Types::Never`, so `Integer[0..5][10..]` == `Integer[0..5] & Integer[10..]`
    # == `Types::Never` (see .narrow and Subtyping.intersect_constraints).
    EMPTY = ::Object.new
    def EMPTY.inspect = 'Plumb::Constraint::EMPTY'
    EMPTY.freeze

    # Matcher kinds whose `#===` is just `#==` — they match exactly ONE value.
    # Two distinct ones are therefore provably disjoint, and as a `#>>` consumer
    # one accepts only its own value. Deliberately excludes Module/Range/Regexp/
    # Set/proc: their `#===` is a type, membership or pattern test that matches
    # many values (and `Set#===` is `#include?` on Ruby >= 3.1).
    LITERAL_MATCHERS = [::String, ::Symbol, ::Numeric, ::TrueClass, ::FalseClass, ::NilClass].freeze

    # The matcher-level form of #literal?, for the one caller that has a matcher
    # but no instance to ask: #matcher_may_match?, which runs from the constructor
    # BEFORE `@matcher` is assigned. Prefer #literal? on an existing Constraint.
    #
    # @param matcher [#===]
    # @return [Boolean] whether `matcher` matches a single value by equality
    def self.literal_matcher?(matcher) = LITERAL_MATCHERS.any? { |kind| matcher.is_a?(kind) }

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
    # when both `base` (a Constraint) and `matcher` are the same kind of knowable
    # matcher (Ranges or Sets), it INTERSECTS them into one over `base`'s own base
    # rather than stacking two checks — so `Integer[0..100][10..]` is
    # `Integer[10..100]`, `Integer[Set[1,2,3]][Set[2,3,4]]` is `Integer[Set[2,3]]`,
    # and `Integer[0..100] >> Integer[0..]` reduces to `Integer[0..100]`. Other
    # matchers stack as before.
    def self.narrow(base, matcher)
      if base.is_a?(Constraint)
        merged = merge_matchers(base.matcher, matcher)
        return Types::Never if merged.equal?(EMPTY) # provably-empty overlap ⇒ bottom
        return narrow(base.base, merged) if merged # recurse: base.base may be a type gate
      end
      new(matcher, base:)
    end

    # Intersection of two knowable matchers of the same kind. Returns the merged
    # matcher on a non-empty overlap, `EMPTY` when the overlap is provably empty
    # (disjoint Ranges / empty Set intersection — callers reduce it to Never), or
    # `nil` to not merge (different kinds, or an incomputable Range overlap — leave
    # the two matchers stacked). Public because AttributeValueMatch narrowing
    # reuses it (see Subtyping) — an attribute constraint intersects its Range/Set
    # values just like a Constraint.
    def self.merge_matchers(a, b)
      if a.is_a?(::Range) && b.is_a?(::Range)
        intersect_ranges(a, b)
      elsif a.is_a?(::Set) && b.is_a?(::Set)
        merged = a & b
        merged.empty? ? EMPTY : merged
      end
    end

    # Intersection of two Ranges as a Range, `EMPTY` when provably empty (disjoint,
    # or a single-point exclusive overlap), or `nil` when incomputable (incomparable
    # endpoints — left to #new's incompatibility check to reject).
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
        return EMPTY if new_begin > new_end
        return EMPTY if new_begin == new_end && new_exclude
      end
      ::Range.new(new_begin, new_end, new_exclude)
    rescue ::ArgumentError, ::TypeError
      nil
    end
    private_class_method :intersect_ranges

    # As the consumer of a `left >> self` chain:
    #   - a refinement (has a base), a Class/Module gate, or a literal matcher
    #     accepts exactly what it validates — itself — so `Integer >>
    #     Integer[1..10]` and `Any[5] >> Any[6]` are correctly rejected (narrow
    #     with `#[]` instead), and the default `#accepted_type` (its resolved
    #     input) is `self`;
    #   - a bare pattern matcher (regex/range/set/proc with no base) narrows
    #     arbitrary input over a domain it cannot name, so it reports Any and opts
    #     out of the check.
    def input_type
      return self if base || @matcher.is_a?(::Module) || literal?

      Types::Any
    end

    # Whether this constraint matches a SINGLE value, by equality — so two
    # distinct ones are provably disjoint (see Subtyping#literal_value).
    def literal? = Constraint.literal_matcher?(@matcher)

    # A matcher validates without changing the value, so `Match >> Match` (of the
    # same matcher) is redundant and `#>>` collapses it — and a redundant `#|`
    # branch absorbs.
    def idempotent? = @base.nil? || @base.idempotent?

    # As the consumer of a `left >> self` chain, a matcher over a CONVERTING base
    # accepts what that base accepts: #call runs `@base` first, so
    # `String.transform(::Integer, :to_i)[0..150]` consumes a String even though it
    # matches against the Integer it produces. Without this it would report the
    # produced type on both sides and read as a plain Integer refinement — letting
    # `Types::Integer >> that` type-check, though the base rejects an Integer.
    #
    # A value-preserving base (the ordinary refinement, `Integer[0..100]`) keeps the
    # default: the node itself, so the matcher is part of what a consumer must
    # satisfy.
    def accepted_type
      return self unless @base && !Plumb::Subtyping.value_preserving?(@base)

      Plumb::Subtyping.accepted_type(@base)
    end

    # The matcher itself changes nothing, so this preserves the value exactly when
    # whatever it REFINES does — #call runs `@base` first.
    #
    # A Constraint is not always a pure check: `#[]` on a conversion re-parents into
    # a Constraint whose base IS that conversion (see Optimizer.reduce_step), so
    # `String.transform(::Integer, :to_i)[0..150]` converts while wearing a
    # matcher's clothes. Reporting true for it told Optimizer.reduce_union and
    # Subtyping.intersect they were free to drop it in favour of a subtype-equal
    # type, which silently discarded the coercion.
    def value_preserving? = @base.nil? || Plumb::Subtyping.value_preserving?(@base)

    # Structural subtyping. A matcher describes the set `base ∩ {x | matcher === x}`
    # (base = everything when nil). `self <= other` when self's set is contained in
    # each of other's conjuncts: within other's base (if any) AND within other's
    # matcher. Against a non-matcher type, a refinement is a subtype of whatever
    # its base is (like AttributeValueMatch).
    def subtype_of?(other)
      return true if self == other

      if other.is_a?(Constraint)
        within_base = other.base.nil? || Plumb::Subtyping.subtype?(self, other.base)
        return true if within_base && within_matcher?(other.matcher)

        # `self` is `base ∩ {matcher}` — a subset of `base` — so whenever the
        # base alone is a subtype of `other`, so is `self`. This is the same
        # fallback the non-Constraint branch below uses; it belongs here too
        # because base types (`Types::String`, `Types::Date`) ARE Constraints,
        # and `within_matcher?` can't peel a transparent base (a Metadata/Policy
        # wrapper, eg. `String.metadata(...).present`) to see the guarantee.
        base ? Plumb::Subtyping.subtype?(base, other) : false
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

    # The caller's description of this matcher, used as its identity when the
    # matcher itself has none (see #==).
    protected def label = @label

    # Two matchers are equal when they match the same thing over the same base.
    #
    # A Proc matcher is compared by LABEL rather than by identity. `#check` — and
    # every policy built on it — closes over a fresh block on each call, so two
    # structurally identical checks hold different Proc objects and would never
    # compare equal. The label is the caller's own description of what the check
    # does, the same role `identity:` plays for Function. Two checks that share a
    # message while testing different things do compare equal; describing them
    # differently is what tells them apart.
    def ==(other)
      return false unless other.instance_of?(self.class) && other.base == base

      if matcher.is_a?(::Proc)
        other.matcher.is_a?(::Proc) && other.label == label
      else
        other.matcher == matcher
      end
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

      @matcher === result.value ? result : result.invalid!(errors: @error)
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
      return matcher.is_a?(klass) if Constraint.literal_matcher?(matcher)

      case matcher
      when ::Module then !!((matcher <= klass) || (klass <= matcher))
      when ::Range then (e = matcher.begin || matcher.end).nil? || e.is_a?(klass)
      when ::Regexp then klass <= ::String || klass <= ::Symbol
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

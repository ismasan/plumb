# frozen_string_literal: true

require 'set'

module Plumb
  # Internal semantic form of Ruby `#===` matchers. Raw matchers are normalized
  # once at a Constraint boundary; nodes then collaborate polymorphically.
  module SemanticMatcher
    class Merge
      attr_reader :node

      class << self
        def merged(node) = new(:merged, node)

        private :new
      end

      def initialize(state, node = nil)
        @state = state
        @node = node
        freeze
      end

      def merged? = @state == :merged
      def empty? = equal?(EMPTY)
      def unknown? = equal?(UNKNOWN)

      EMPTY = new(:empty)
      UNKNOWN = new(:unknown)
    end

    class Node
      attr_reader :raw

      def initialize(raw)
        @raw = raw
        freeze
      end

      def kind = :opaque
      def singleton? = false
      def nominal? = false
      def matcher_domain = []
      def value_domain = raw.class
      def error_message = "Must match #{raw.inspect}"
      def matches_value(_candidate) = Relation::UNKNOWN

      def equivalent?(other)
        other.instance_of?(self.class) && raw == other.raw
      end

      def subset_of(other)
        return Relation::PROVEN if equivalent?(other)

        other.subset_from_opaque(self)
      end

      def subset_from_opaque(_other) = Relation::UNKNOWN
      def subset_from_nominal(_other) = Relation::UNKNOWN
      def subset_from_literal(_other) = Relation::UNKNOWN
      def subset_from_text_literal(other) = subset_from_literal(other)
      def subset_from_numeric_literal(other) = subset_from_literal(other)
      def subset_from_finite_set(_other) = Relation::UNKNOWN
      def subset_from_range(_other) = Relation::UNKNOWN
      def subset_from_pattern(_other) = Relation::UNKNOWN

      def overlap(other)
        return Relation::PROVEN if equivalent?(other)

        other.overlap_with_opaque(self)
      end

      def overlap_with_opaque(_other) = Relation::UNKNOWN
      def overlap_with_nominal(_other) = Relation::UNKNOWN
      def overlap_with_literal(_other) = Relation::UNKNOWN
      def overlap_with_text_literal(other) = overlap_with_literal(other)
      def overlap_with_numeric_literal(other) = overlap_with_literal(other)
      def overlap_with_finite_set(_other) = Relation::UNKNOWN
      def overlap_with_range(_other) = Relation::UNKNOWN
      def overlap_with_pattern(_other) = Relation::UNKNOWN

      def intersect(_other) = Merge::UNKNOWN
      def intersect_with_finite_set(_other) = Merge::UNKNOWN
      def intersect_with_range(_other) = Merge::UNKNOWN
    end

    class Opaque < Node
    end

    class CollectionMatcher < Opaque
      def kind = :collection_matcher
      def error_message = "Must be equal to #{raw}"
    end

    class Literal < Node
      def kind = :literal
      def singleton? = true
      def matcher_domain = [value_domain]
      def matches_value(candidate) = Relation.from(raw === candidate)
      def error_message = "Must be equal to #{raw}"

      def subset_of(other)
        return Relation::PROVEN if equivalent?(other)

        other.subset_from_literal(self)
      end

      def subset_from_literal(_other) = Relation::DISPROVEN

      def overlap(other)
        return Relation::PROVEN if equivalent?(other)

        other.overlap_with_literal(self)
      end

      def overlap_with_literal(_other) = Relation::DISPROVEN
      def overlap_with_nominal(other) = other.overlap_with_literal(self)
      def overlap_with_range(other) = other.overlap_with_literal(self)
      def overlap_with_pattern(other) = other.overlap_with_literal(self)
    end

    class TextLiteral < Literal
      def kind = :text_literal

      def subset_of(other)
        return Relation::PROVEN if equivalent?(other)

        other.subset_from_text_literal(self)
      end

      def overlap(other)
        return Relation::PROVEN if equivalent?(other)

        other.overlap_with_text_literal(self)
      end
    end

    class NumericLiteral < Literal
      def kind = :numeric_literal
      def value_domain = ::Numeric

      def subset_of(other)
        return Relation::PROVEN if equivalent?(other)

        other.subset_from_numeric_literal(self)
      end

      def overlap(other)
        return Relation::PROVEN if equivalent?(other)

        other.overlap_with_numeric_literal(self)
      end
    end

    class Nominal < Node
      def kind = :nominal
      def nominal? = true
      def matcher_domain = raw.is_a?(::Class) ? [raw] : []
      def matches_value(candidate) = Relation.from(raw === candidate)

      def error_message
        raw.is_a?(::Class) ? "Must be a #{raw}" : super
      end

      def subset_of(other)
        return Relation::PROVEN if equivalent?(other)

        other.subset_from_nominal(self)
      end

      def subset_from_nominal(other) = Relation.from((other.raw <= raw) == true)
      def subset_from_literal(other) = matches_value(other.raw)
      def subset_from_numeric_literal(_other) = SemanticMatcher.wrap(::Numeric).subset_of(self)
      def subset_from_finite_set(other) = other.members_match(self)
      def subset_from_range(other) = other.endpoints_within(self)

      def subset_from_pattern(other)
        Relation.all(other.matcher_domain.map { |domain| SemanticMatcher.wrap(domain).subset_of(self) })
      end

      def overlap(other)
        return Relation::PROVEN if equivalent?(other)

        other.overlap_with_nominal(self)
      end

      def overlap_with_nominal(other)
        return Relation::PROVEN if subset_from_nominal(other).proven? || other.subset_from_nominal(self).proven?
        return Relation::DISPROVEN if raw.is_a?(::Class) && other.raw.is_a?(::Class)

        Relation::UNKNOWN # unrelated mixins may share an implementing class
      end

      def overlap_with_literal(other) = Relation.from(other.raw.is_a?(raw))
      def overlap_with_range(other) = other.overlap_with_nominal(self)
      def overlap_with_pattern(other) = other.overlap_with_nominal(self)
    end

    class FiniteSet < Node
      def kind = :finite_set
      def matcher_domain = raw.map(&:class).uniq
      def matches_value(candidate) = Relation.from(raw === candidate)

      def subset_of(other)
        return Relation::PROVEN if equivalent?(other)

        other.subset_from_finite_set(self)
      end

      def subset_from_literal(other) = matches_value(other.raw)
      def subset_from_numeric_literal(_other) = Relation::DISPROVEN
      def subset_from_finite_set(other) = Relation.from(other.raw.subset?(raw))

      def members_match(other)
        Relation.all(raw.map { |member| other.matches_value(member) })
      end

      def overlap(other)
        return Relation::PROVEN if equivalent?(other)

        other.overlap_with_finite_set(self)
      end

      def overlap_with_finite_set(other)
        Relation.from(!(raw & other.raw).empty?)
      end

      def intersect(other) = other.intersect_with_finite_set(self)

      def intersect_with_finite_set(other)
        merged = raw & other.raw
        merged.empty? ? Merge::EMPTY : Merge.merged(self.class.new(merged))
      end
    end

    class Interval < Node
      def kind = :range

      def matcher_domain
        endpoint = raw.begin || raw.end
        endpoint.nil? ? [] : [SemanticMatcher.value_domain(endpoint)]
      end

      def matches_value(candidate) = Relation.from(raw === candidate)
      def error_message = "Must be within #{raw}"

      def subset_of(other)
        return Relation::PROVEN if equivalent?(other)

        other.subset_from_range(self)
      end

      def subset_from_literal(other) = matches_value(other.raw)
      def subset_from_finite_set(other) = other.members_match(self)

      def subset_from_range(other)
        lo = if raw.begin.nil?
               Relation::PROVEN
             elsif other.raw.begin.nil?
               Relation::DISPROVEN
             else
               Relation.from(raw.cover?(other.raw.begin))
             end
        Relation.all([lo, other.end_within(self)])
      rescue ::ArgumentError, ::TypeError
        Relation::UNKNOWN
      end

      def endpoints_within(nominal)
        endpoints = [raw.begin, raw.end].compact
        return Relation::UNKNOWN if endpoints.empty?

        Relation.all(endpoints.map { |endpoint| nominal.matches_value(endpoint) })
      end

      def end_within(outer)
        return Relation::PROVEN if outer.raw.end.nil?
        return Relation::DISPROVEN if raw.end.nil?

        cmp = raw.end <=> outer.raw.end
        return Relation::UNKNOWN if cmp.nil?

        Relation.from(!raw.exclude_end? && outer.raw.exclude_end? ? cmp.negative? : cmp <= 0)
      end

      def overlap(other)
        return Relation::PROVEN if equivalent?(other)

        other.overlap_with_range(self)
      end

      def overlap_with_nominal(other)
        endpoint = raw.begin || raw.end
        endpoint.nil? ? Relation::UNKNOWN : other.matches_value(endpoint)
      end

      def overlap_with_literal(other) = matches_value(other.raw)

      def overlap_with_range(other)
        merged = intersect_with_range(other)
        return Relation::DISPROVEN if merged.empty?
        return Relation::PROVEN if merged.merged?

        Relation::UNKNOWN
      end

      def intersect(other) = other.intersect_with_range(self)

      def intersect_with_range(other)
        ab = raw.begin
        bb = other.raw.begin
        new_begin = ab.nil? ? bb : (bb.nil? ? ab : (ab >= bb ? ab : bb))
        ae = raw.end
        be = other.raw.end
        new_end, new_exclude =
          if ae.nil? then [be, other.raw.exclude_end?]
          elsif be.nil? then [ae, raw.exclude_end?]
          elsif ae < be then [ae, raw.exclude_end?]
          elsif be < ae then [be, other.raw.exclude_end?]
          else [ae, raw.exclude_end? || other.raw.exclude_end?]
          end
        unless new_begin.nil? || new_end.nil?
          return Merge::EMPTY if new_begin > new_end
          return Merge::EMPTY if new_begin == new_end && new_exclude
        end
        Merge.merged(self.class.new(::Range.new(new_begin, new_end, new_exclude)))
      rescue ::ArgumentError, ::TypeError
        Merge::UNKNOWN
      end
    end

    class Pattern < Node
      def kind = :pattern
      def matcher_domain = [::String, ::Symbol]
      def matches_value(candidate) = Relation.from(raw === candidate)

      def subset_of(other)
        return Relation::PROVEN if equivalent?(other)

        other.subset_from_pattern(self)
      end

      def subset_from_text_literal(other) = matches_value(other.raw.to_s)

      def overlap(other)
        return Relation::PROVEN if equivalent?(other)

        other.overlap_with_pattern(self)
      end

      def overlap_with_nominal(other)
        Relation.any(matcher_domain.map { |domain| SemanticMatcher.wrap(domain).overlap(other) })
      end

      def overlap_with_literal(other)
        return Relation::UNKNOWN unless other.is_a?(TextLiteral)

        matches_value(other.raw.to_s)
      end
    end

    module_function

    # The only raw-class normalization switch. Core algebra receives nodes.
    def wrap(raw)
      return raw if raw.is_a?(Node)

      case raw
      when ::Module then Nominal.new(raw)
      when ::Range then Interval.new(raw)
      when ::Set then FiniteSet.new(raw)
      when ::Regexp then Pattern.new(raw)
      when ::Numeric then NumericLiteral.new(raw)
      when ::String, ::Symbol then TextLiteral.new(raw)
      when ::TrueClass, ::FalseClass, ::NilClass then Literal.new(raw)
      when ::Array, ::Hash then CollectionMatcher.new(raw)
      else Opaque.new(raw)
      end
    end

    def value_domain(raw) = wrap(raw).value_domain
    def matcher_domain(raw) = wrap(raw).matcher_domain
    def singleton?(raw) = wrap(raw).singleton?
    def nominal?(raw) = wrap(raw).nominal?
    def error_message(raw) = wrap(raw).error_message

    def merge(left, right)
      wrap(left).intersect(wrap(right))
    end

  end
  private_constant :SemanticMatcher
end

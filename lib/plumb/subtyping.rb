# frozen_string_literal: true

module Plumb
  # The structural subtype/subset relation over types, the value-set
  # disjointness relation, and the `#>>` composition type-check that builds on
  # them. Methods are module functions: call them as `Plumb::Subtyping.foo`.
  module Subtyping
    module_function

    # The structural subtype/subset relation over types.
    #
    # `subtype?(a, b)` answers "is every value described by `a` also described
    # by `b`?", i.e. `a <= b`. Both `a` and `b` are normalized to Composables
    # (raw Ruby classes/values become a MatchClass), so `Types::String` and
    # `String` compare the same way.
    #
    # This engine knows ONLY the composition algebra — refinement (And), union
    # (Or), conversion (Transform) and the top type (AnyClass). Everything else
    # (atomic matchers, covariant containers, Hash width/depth, custom types) is
    # decided by the type's own #subtype_of? leaf hook (see Composable). It never
    # calls #<= (which would recurse back here).
    #
    # @param a [Composable, Class, Object] subtype candidate
    # @param b [Composable, Class, Object] supertype candidate
    # @return [Boolean]
    def subtype?(a, b)
      a = Composable.wrap(a)
      b = Composable.wrap(b)

      return true if a.equal?(b) || a == b
      return true if b.is_a?(AnyClass)  # X <= Top
      return false if a.is_a?(AnyClass) # Top <= X only when X is Top (handled above)

      # A Transform changes the value, so its identity for subtyping is what it
      # *produces* — its output_type. Input constraints don't carry through.
      return subtype?(a.output_type, b) if a.is_a?(Transform)
      return subtype?(a, b.output_type) if b.is_a?(Transform)

      # Unions
      return a.children.all? { |m| subtype?(m, b) } if a.is_a?(Or) # (A|B) <= C
      return b.children.any? { |m| subtype?(a, m) } if b.is_a?(Or) # A <= (B|C)

      # Refinements are intersections: the longer the And chain, the narrower.
      return b.children.all? { |bb| subtype?(a, bb) } if b.is_a?(And) # a <= (b1 ∧ b2)
      return a.children.any? { |aa| subtype?(aa, b) } if a.is_a?(And) # (a1 ∧ a2) <= b

      a.subtype_of?(b)
    end

    # A leaf type whose single child is a raw (non-Composable) Ruby matcher or
    # value — eg. MatchClass, ValueClass, StaticClass. These bottom out in
    # #atomic_subtype? rather than recursing.
    def atomic?(type)
      type.respond_to?(:children) &&
        type.children.size == 1 &&
        !type.children.first.is_a?(Composable)
    end

    # The subtype relation between two raw matchers (a Class/Module, Range,
    # Regexp, or literal value). `atomic_subtype?(lm, rm)` is "does `lm` describe
    # a subset of what `rm` describes?".
    def atomic_subtype?(lm, rm)
      return true if lm == rm
      return regex_equal?(lm, rm) if lm.is_a?(::Regexp) && rm.is_a?(::Regexp)

      case rm
      when ::Module
        case lm
        when ::Module then class_le?(lm, rm)        # Integer <= Numeric
        when ::Range then range_in_class?(lm, rm)   # (1..10) <= Integer
        when ::Regexp then class_le?(::String, rm)  # /x/ matches Strings
        else rm === lm                              # value 5 <= Integer
        end
      when ::Range
        case lm
        when ::Range then range_in_range?(lm, rm)   # (1..10) <= (0..20)
        when ::Module, ::Regexp then false
        else rm === lm                              # value within range
        end
      when ::Regexp
        case lm
        when ::String, ::Symbol then rm === lm.to_s # literal string matches regex
        else false
        end
      else
        lm == rm                                    # literal value equality
      end
    end

    def class_le?(a, b)
      return false unless a.is_a?(::Module) && b.is_a?(::Module)

      (a <= b) == true
    end

    def range_in_class?(range, klass)
      e = range.begin || range.end
      !e.nil? && e.is_a?(klass)
    end

    def range_in_range?(inner, outer)
      lo_ok = outer.begin.nil? || (!inner.begin.nil? && outer.cover?(inner.begin))
      hi_ok = outer.end.nil? || (!inner.end.nil? && outer.cover?(inner.end))
      lo_ok && hi_ok
    end

    def regex_equal?(a, b)
      a.is_a?(::Regexp) && b.is_a?(::Regexp) && a.source == b.source
    end

    # Validate that two steps can be composed sequentially (`left >> right`):
    # the values `left` produces must be able to flow into `right`. We raise only
    # when the two are *provably disjoint* — ie. nothing `left` produces could
    # ever be accepted by `right` (a dead composition). This permits legitimate
    # narrowing (`String >> String[/d/]`, `transform(Integer) >> Integer[1..10]`)
    # while rejecting dead ends (`String >> Integer`, `String[/nope/] >>
    # String["yes"]`).
    #
    # Permissive by design — when either side reports Any (the top / unknown
    # type) it opts out entirely. Opaque steps (plain procs/Steps), value-level
    # transforms (built directly via #transform/#build) and constraints report
    # Any on the relevant side, so only genuine type clashes raise.
    #
    # @raise [Plumb::TypeError] when the chain is provably dead.
    def check_composable!(left, right)
      produced = resolved_output(left)
      # opaque left (unknown output) or opaque right (accepts anything) -> opt out
      return if produced.is_a?(AnyClass) || resolved_input(right).is_a?(AnyClass)

      accepted = accepted_type(right)
      return if accepted.is_a?(AnyClass)

      # Each type owns the reason (if any) it can't feed `accepted` — see
      # Composable#composition_error.
      reason = produced.composition_error(accepted)
      return unless reason

      raise Plumb::TypeError, "cannot compose #{left.inspect} >> #{right.inspect}: #{reason}"
    end

    # What `type` will accept without rejecting it outright. A conversion
    # (Transform) consumes its declared input; any other type (a validator or
    # refinement) accepts the values it would itself pass — its own constraint
    # (its resolved output). Transparent wrappers are peeled first.
    def accepted_type(type)
      type = unwrap_transparent(type)
      type.is_a?(Transform) ? resolved_input(type) : resolved_output(type)
    end

    # Peel transparent wrappers (Policy/Metadata/Node) down to the wrapped type.
    def unwrap_transparent(type)
      case type
      when Policy then unwrap_transparent(type.children.first)
      when Metadata then unwrap_transparent(type.type)
      when Composable::Node then unwrap_transparent(type.type)
      else type
      end
    end

    # #output_type / #input_type are shallow (one level): an And's output_type is
    # its right child, which may itself be an opaque Step (output Any) or another
    # composite. Follow the chain to a fixpoint so the composition check sees the
    # effective produced/accepted type (and so opaque steps resolve to Any).
    def resolved_output(type, depth = 0)
      nxt = type.output_type
      return type if depth >= 50 || nxt.equal?(type) || nxt == type

      resolved_output(nxt, depth + 1)
    end

    def resolved_input(type, depth = 0)
      nxt = type.input_type
      return type if depth >= 50 || nxt.equal?(type) || nxt == type

      resolved_input(nxt, depth + 1)
    end

    # Are the value sets described by `a` and `b` provably disjoint (no value
    # belongs to both)? Conservative: returns false whenever we cannot prove
    # disjointness, so the composition check only raises when it is certain.
    #
    # Like #subtype?, this handles the composition algebra (Top/Transform/Or/
    # And) and delegates the leaf case to the type's own #disjoint_from? hook
    # (see Composable).
    def disjoint?(a, b)
      a = Composable.wrap(a)
      b = Composable.wrap(b)
      return false if a.is_a?(AnyClass) || b.is_a?(AnyClass)

      # A Transform's value identity is what it produces.
      return disjoint?(a.output_type, b) if a.is_a?(Transform)
      return disjoint?(a, b.output_type) if b.is_a?(Transform)

      # Union: disjoint from `b` only if EVERY member is.
      return a.children.all? { |m| disjoint?(m, b) } if a.is_a?(Or)
      return b.children.all? { |m| disjoint?(a, m) } if b.is_a?(Or)

      # Intersection/refinement: `a1 ∧ a2` is disjoint from `b` if EITHER factor is.
      return a.children.any? { |m| disjoint?(m, b) } if a.is_a?(And)
      return b.children.any? { |m| disjoint?(a, m) } if b.is_a?(And)

      a.disjoint_from?(b)
    end

    # Disjointness over two raw matchers (Class/Module, Range, Regexp, literal).
    def atomic_disjoint?(am, bm)
      return false if am == bm
      return true if literal?(am) && literal?(bm)        # distinct literal singletons
      return !(bm === am) if literal?(am)                # is the literal a member of bm?
      return !(am === bm) if literal?(bm)
      return range_disjoint?(am, bm) if am.is_a?(::Range) && bm.is_a?(::Range)
      return false if am.is_a?(::Regexp) && bm.is_a?(::Regexp) # can't prove

      ca = domain_class(am)
      cb = domain_class(bm)
      return false if ca.nil? || cb.nil?

      class_disjoint?(ca, cb)
    end

    # A raw matcher that denotes a single value rather than a type/pattern/range.
    def literal?(matcher)
      !matcher.is_a?(::Module) && !matcher.is_a?(::Range) && !matcher.is_a?(::Regexp)
    end

    # The Ruby class a matcher's values belong to.
    def domain_class(matcher)
      case matcher
      when ::Module then matcher
      when ::Regexp then ::String
      when ::Range then (matcher.begin || matcher.end)&.class
      else matcher.class
      end
    end

    def range_disjoint?(r1, r2)
      return false unless r1.begin && r1.end && r2.begin && r2.end

      r1.end < r2.begin || r2.end < r1.begin
    end

    # Two *classes* (not modules) with no subclass relationship share no
    # instances. Modules can be mixed into anything, so we never claim them
    # disjoint.
    def class_disjoint?(a, b)
      return false unless a.is_a?(::Class) && b.is_a?(::Class)

      !(a <= b || b <= a)
    end
  end
end

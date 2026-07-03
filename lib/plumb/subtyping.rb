# frozen_string_literal: true

require 'plumb/type_cache'

module Plumb
  # The structural subtype/subset relation over types, and the `#>>`
  # composition type-check (subsumption) that builds on it. Methods are module
  # functions: call them as `Plumb::Subtyping.foo`.
  module Subtyping
    module_function

    # The structural subtype/subset relation over types.
    #
    # `subtype?(a, b)` answers "is every value described by `a` also described
    # by `b`?", i.e. `a <= b`. Both `a` and `b` are normalized to Composables
    # (raw Ruby classes/values become a Constraint), so `Types::String` and
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

      # `a` decides via its #subtype_of? leaf; if it can't (it doesn't know about
      # `b`), `b` may claim `a` via #supertype_of? — the mirror hook for
      # supertype-driven relations like Interface duck-typing.
      a.subtype_of?(b) || b.supertype_of?(a)
    end

    # A leaf type whose single child is a raw (non-Composable) Ruby matcher or
    # value — eg. Constraint, ValueClass, StaticClass. These bottom out in
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
        when ::Set then lm.all? { |e| rm === e }    # Set[1,2,3] <= Integer
        else rm === lm                              # value 5 <= Integer
        end
      when ::Range
        case lm
        when ::Range then range_in_range?(lm, rm)   # (1..10) <= (0..20)
        when ::Set then lm.all? { |e| rm === e }    # Set[1,2,3] <= (0..10)
        when ::Module, ::Regexp then false
        else rm === lm                              # value within range
        end
      when ::Set
        case lm
        when ::Set then lm.subset?(rm)              # Set[2,3] <= Set[1,2,3,4]
        when ::Module, ::Range, ::Regexp then false # infinite domain ⊄ finite set
        else rm === lm                              # value is a member
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

    # Validate that two steps can be composed sequentially (`left >> right`).
    # Composition is typed by subsumption, like function application in any
    # statically-typed language: everything `left` produces must be acceptable
    # to `right`, i.e. `produced(left) <: accepted(right)`. Otherwise the chain
    # would reject some of `left`'s output and we raise.
    #
    # To *narrow* a value (where only some of it flows through), use `#[]` /
    # `#transform(...)[...]` — a refinement is a runtime-checked cast, built
    # directly and not subject to this check.
    #
    # Permissive only where types are genuinely unknown: when either side
    # reports Any (opaque steps/procs, value-level transforms, narrowing
    # matchers), it opts out.
    #
    # @raise [Plumb::TypeError] when `left`'s output is not a subtype of what
    #   `right` accepts.
    def check_composable!(left, right)
      produced = resolved_output(left)
      # opaque left (unknown output) or opaque right (accepts anything) -> opt out
      return if produced.is_a?(AnyClass) || resolved_input(right).is_a?(AnyClass)

      accepted = accepted_type(right)
      return if accepted.is_a?(AnyClass) || subtype?(produced, accepted)

      raise Plumb::TypeError,
            "cannot compose #{left.inspect} >> #{right.inspect}: " \
            "#{produced.inspect} (produced) is not a subtype of #{accepted.inspect} (accepted); " \
            'narrow with #[] if this is intentional'
    end

    # Rung-1 structural reduction of `left >> right`. When `right` is a refinement
    # (a `Constraint` chain) whose ROOT is a base-type (Module) gate that `left`'s
    # output already guarantees, that gate is a duplicated runtime check: re-parent
    # `right`'s refinement matchers onto `left` and drop it. Returns the reduced
    # type, or `nil` to fall back to `And.new`.
    #
    # Keyed on the root TYPE only (`subtype?(left_output, root)`), NOT on matcher
    # values — so `Integer[0..100] >> Integer[-10..110]` becomes
    # `Integer[0..100][-10..110]` (the `-10..110` range is preserved), not the
    # value-subsumed `Integer[0..100]` (that would be rung 2).
    #
    #   matchers=[-10..110], root=Constraint(::Integer), left guarantees Integer
    #   => Constraint(-10..110, base: Integer[0..100]) == Integer[0..100][-10..110]
    #
    # Degenerate `left >> Integer` (`matchers == []`) returns `left` — a pure
    # redundant type gate removed.
    def reduce_step(left, right)
      return nil unless right.is_a?(Constraint)

      matchers = [] # innermost-first, excludes the root gate
      node = right
      while node.is_a?(Constraint) && node.base
        matchers.unshift(node.matcher)
        node = node.base
      end
      root = node
      return nil unless root.is_a?(Constraint) && root.matcher.is_a?(::Module)
      return nil unless subtype?(resolved_output(left), root)

      # Stack right's refinements onto left; Constraint.narrow intersects Ranges
      # so `Integer[0..100] >> Integer[0..]` collapses to `Integer[0..100]`.
      matchers.reduce(left) { |acc, m| Constraint.narrow(acc, m) }
    end

    # Join-dual of `reduce_step`: absorption for `a | b`. If one branch's value
    # set is contained in the other's (`a <= b`), the union equals the wider
    # branch (`a ∪ b == b`), so drop the narrower — and `a | a` dedupes. Returns
    # the surviving type, or nil to fall back to `Or.new`.
    #
    # Guarded to VALUE-PRESERVING refinements only. `subtype?` identifies a
    # Transform by its OUTPUT type, so `subtype?(String->Integer, Numeric)` is
    # true even though that branch accepts Strings a bare Numeric rejects —
    # reducing there would silently drop a coercion branch. Only when both
    # branches pass values through unchanged does `subtype?` reflect the accepted
    # input domain, making the drop behaviour-preserving.
    def reduce_union(a, b)
      return nil unless value_preserving?(a) && value_preserving?(b)
      return b if subtype?(a, b) # a ⊆ b — keep the wider b (also dedupes a == b)
      return a if subtype?(b, a) # b ⊆ a — keep the wider a

      nil
    end

    # Does `type` return its input unchanged on success (a coreflexive
    # refinement)? Delegates to the type's polymorphic #value_preserving? hook —
    # so custom types opt in by defining it — and memoizes per frozen node in
    # TypeCache, a pure structural predicate like #accepted_type. Transforms and
    # value-building containers (Hash/Array/Tuple/…) change the value and stay
    # false; refinements and their And/Or compositions are true.
    def value_preserving?(type)
      TypeCache.fetch(:value_preserving, type) { type.value_preserving? }
    end

    # What `type` will accept without rejecting it outright, when it's the
    # consumer of a `left >> type` chain. The type itself answers via its
    # #accepted_type hook (default: its resolved input; refinements and Hash
    # override it — see Composable#accepted_type). Transparent wrappers are
    # peeled first so the wrapped type answers. Memoized per node in TypeCache
    # (frozen nodes only) — this is the sole consumer of #accepted_type, so
    # caching here covers every type, eg. HashClass's per-field rebuild.
    def accepted_type(type)
      type = unwrap_transparent(type)
      TypeCache.fetch(:accepted_type, type) { type.accepted_type }
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
    # Memoized per node in TypeCache (frozen nodes only), so re-resolving a chain
    # that was already walked — eg. each step of A >> B >> C >> D — is O(1).
    def resolved_output(type, depth = 0)
      TypeCache.fetch(:resolved_output, type) do
        nxt = type.output_type
        if depth >= 50 || nxt.equal?(type) || nxt == type
          type
        else
          resolved_output(nxt, depth + 1)
        end
      end
    end

    def resolved_input(type, depth = 0)
      TypeCache.fetch(:resolved_input, type) do
        nxt = type.input_type
        if depth >= 50 || nxt.equal?(type) || nxt == type
          type
        else
          resolved_input(nxt, depth + 1)
        end
      end
    end
  end
end

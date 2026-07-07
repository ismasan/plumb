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
      # A refinement `And` (a `where`-clause chain, or any value-preserving
      # intersection) narrows by each conjunct in turn: `left / (b ∧ c)` is
      # `(left / b) / c`. An `And` carrying a transform changes the value and is
      # a barrier, so it is left intact (falls through to the Constraint check
      # below, which bails).
      if right.is_a?(And) && value_preserving?(right)
        l = reduce_step(left, right.children[0]) || And.new(left, right.children[0])
        return reduce_step(l, right.children[1]) || And.new(l, right.children[1])
      end

      # An attribute constraint intersects into `left`'s clause on the same
      # attribute — like Constraint.narrow intersects Ranges — or stacks on when
      # there is none. `String.where(size: 0..40) / .where(size: 10..100)` ->
      # `.where(size: 10..40)`, one `String` check.
      return narrow_attribute(left, right) if right.is_a?(AttributeValueMatch)

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

    # Narrow `left` by attribute constraint `avm`: intersect it into `left`'s
    # existing clause on the same attribute+base type (mirroring how
    # Constraint.narrow intersects Range matchers), or stack it on when there is
    # no such clause. Always reduces (never bails) — an AVM is a value-narrowing
    # refinement, so there is no duplicated type gate to keep it apart.
    def narrow_attribute(left, avm)
      merge_attribute_into(left, avm) || And.new(left, avm)
    end

    # `left` rebuilt with `avm` merged into its matching same-attribute clause,
    # or nil when `left` has none (the caller then stacks). Prefers the outermost
    # (most-recently-added) clause.
    def merge_attribute_into(left, avm)
      case left
      when AttributeValueMatch
        return nil unless left.attr_name == avm.attr_name && compatible_base?(left.type, avm.type)

        merged = intersect_attribute_values(left.value, avm.value)
        merged.nil? ? nil : AttributeValueMatch.new(left.type, left.attr_name, merged)
      when And
        if (right = merge_attribute_into(left.children[1], avm))
          And.new(left.children[0], right)
        elsif (leftc = merge_attribute_into(left.children[0], avm))
          And.new(leftc, left.children[1])
        end
      end
    end

    # Subtype test between two attribute-constraint VALUES (the `value` of a
    # `where(attr: value)` clause). A value is either a full Plumb type — compared
    # structurally with #subtype? — or a raw `===`-matcher (Range/Set/literal/
    # Regexp/Array/Hash), compared with #atomic_subtype?. The split is load-
    # bearing: #subtype? wraps its arguments, and Composable.wrap turns a raw
    # Array into `Array[element]` (raising on multi-element arrays) and a Hash into
    # a record type — but an AttributeValueMatch matches its value with plain
    # `===`, which is exactly what #atomic_subtype? models. Mirrors how a
    # Constraint's matcher can be either kind.
    def value_subtype?(a, b)
      if a.is_a?(Composable) || b.is_a?(Composable)
        subtype?(a, b)
      else
        atomic_subtype?(a, b)
      end
    end

    # Intersect two attribute-constraint values into a single value, or nil to
    # keep the two clauses stacked. Raw Ranges/Sets intersect to their (possibly
    # narrower) overlap via Constraint.merge_matchers; a Plumb-typed value reduces
    # only by subsumption — keeping the narrower — and otherwise stays stacked
    # (intersecting two arbitrary Plumb types into one clause isn't representable).
    def intersect_attribute_values(a, b)
      return a if a == b

      if a.is_a?(Composable) || b.is_a?(Composable)
        return a if value_subtype?(a, b)
        return b if value_subtype?(b, a)

        nil
      else
        Constraint.merge_matchers(a, b)
      end
    end

    # Two same-attribute clauses may merge when their base types are subtype-
    # comparable — so a clause built on `String` and one built on the accumulated
    # `String.where(size: …)` (as chained `#where` produces) still fold together.
    def compatible_base?(a, b)
      a == b || subtype?(a, b) || subtype?(b, a)
    end

    # In `left >> right`, is `right` a no-op that `left` already guarantees?
    # True when `right` preserves values AND every value `left` produces already
    # satisfies it (`left <= right`), so `right` can neither reject nor change
    # them — eg. `String.where(size: 3..10) >> String.where(size: 0..)` drops the
    # vacuous `size: 0..`. This is what reduce_step does for a Constraint chain,
    # generalized to any value-preserving refinement (a `where`/AVM And, a nested
    # Or). It tests REAL subsumption via #subtype?, not check_composable!'s type-
    # compat check — a value-narrowing refinement (AVM) opts out of the latter
    # (its #input_type is Any), so check_composable! can't tell it apart.
    def redundant_refinement?(left, right)
      value_preserving?(right) && subtype?(left, right)
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

    # Distributive factoring — the join-dual of reduce_union's absorption:
    # `(P >> A) | (P >> B)` factors to `P >> (A | B)` when the shared left prefix
    # `P` is value-preserving, so `P` is validated once instead of per branch.
    #
    # SOUNDNESS. The un-factored union runs `P` once per branch (the Or re-runs
    # it in the right branch when the left fails). Factoring runs it once, which
    # is behaviour-preserving iff `P` is referentially transparent. A VALUE-
    # PRESERVING `P` guarantees this: it never alters the value, so both forms
    # feed the divergent suffixes the identical input. The guard is per prefix
    # STEP (below), so the suffixes may be anything (incl. transforms) and a
    # transform prefix — whose purity is unprovable — halts the shared prefix.
    #
    # Both branches are flattened to their `>>` step lists (#steps unwraps already-
    # factored `:refined_union` nodes, so a third branch folds into an existing
    # `P >> (…)` rather than re-checking `P` — n-ary folding). The longest common
    # value-preserving step prefix is pulled out; the divergent tails become the
    # Or. Runs AFTER reduce_union, so a prefix consuming a whole branch was
    # already absorbed. The result is decorated `:refined_union` so visitors fold
    # the type-less disjunction into P's type spec; runtime is the plain And.
    def factor_union(a, b)
      sa = steps(a)
      sb = steps(b)
      k = common_step_prefix(sa, sb)
      return nil if k.zero? # disjoint prefixes — nothing shared
      return nil if k == sa.size || k == sb.size # one is a prefix of the other (absorption's job)

      inner = Or.new(rebuild(sa.drop(k)), rebuild(sb.drop(k)))
      And.new(rebuild(sa.take(k)), inner).as_node(:refined_union)
    end

    # Flatten a type into its `>>` execution steps. A fused Constraint chain
    # (`String[/d/]`) unfolds to its base then a bare matcher refinement; an And
    # to its two sides; an already-factored `:refined_union` node is peeled so its
    # shared prefix re-exposes for n-ary folding. Everything else (root gate,
    # transform, Or, container) is atomic. Only `:refined_union` nodes are peeled
    # — Metadata/Policy/other Nodes carry identity we must not factor away.
    def steps(type)
      type = type.type if type.is_a?(Composable::Node) && type.node_name == :refined_union
      case type
      when And then steps(type.input_type) + steps(type.output_type)
      when Constraint then type.base ? steps(type.base) + [Constraint.new(type.matcher)] : [type]
      else [type]
      end
    end

    # Length of the longest leading run of steps the two lists agree on AND that
    # is value-preserving — the sound-to-factor shared prefix.
    def common_step_prefix(sa, sb)
      max = sa.size < sb.size ? sa.size : sb.size
      i = 0
      i += 1 while i < max && sa[i] == sb[i] && value_preserving?(sa[i])
      i
    end

    # Re-fold a step list into a type, fusing consecutive Constraint refinements
    # back into a Constraint chain (`[String, /d/] → String[/d/]`) and using And at
    # a non-fusable boundary (a transform or an Or suffix).
    def rebuild(list)
      list.reduce { |left, step| compose_step(left, step) }
    end

    def compose_step(left, right)
      if left.is_a?(Constraint) && right.is_a?(Constraint) && right.base.nil?
        Constraint.narrow(left, right.matcher)
      else
        And.new(left, right)
      end
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

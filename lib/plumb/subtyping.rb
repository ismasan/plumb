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
    # (Or), conversion (Function) and the top type (AnyClass). Everything else
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

      # A Deferred stands in for the type it lazily materializes (via #type). We
      # unwrap it here so the rest of the algebra never sees a Deferred. Recursive
      # (self-referential) types would otherwise loop forever, so we break cycles
      # coinductively: keyed by the identity of the (a, b) PAIR — the same Deferred
      # may be compared against different RHSs on sibling branches, so a single-node
      # marker would give false positives. Re-encountering a pair mid-recursion
      # means we've closed a loop in a self-referential type: assume it holds (the
      # greatest fixpoint) and let the surrounding structure confirm or refute it.
      #
      # `seen` is fiber-local (Thread.current[] is fiber-local in Ruby, not
      # thread-local): a subtype? query never yields, so its recursion owns the set
      # for its whole run, and concurrent fibers each get an isolated one. The
      # ensure-delete unwinds each pair, so the set is empty again between queries.
      if a.is_a?(Deferred) || b.is_a?(Deferred)
        seen = (Thread.current[:plumb_subtype_seen] ||= Set.new)
        key = [a.object_id, b.object_id]
        return true if seen.include?(key)

        seen.add(key)
        begin
          a = a.type if a.is_a?(Deferred)
          b = b.type if b.is_a?(Deferred)
          return subtype?(a, b)
        ensure
          seen.delete(key)
        end
      end

      return true if b.is_a?(AnyClass)  # X <= Top
      return false if a.is_a?(AnyClass) # Top <= X only when X is Top (handled above)

      # A value-converting type (Function, or any custom type that opts in) is
      # identified for subtyping by what it *produces*, not what it consumes, so we
      # reduce `a <= b` to `produced(a) <= b` before consulting the leaf hooks. A
      # type declares its produced identity via #subtype_identity (default: self).
      #
      # The `!equal?` guard is the safety rail: we only reduce when the projection
      # is a DISTINCT node. This makes the "distinct output type" invariant
      # structural rather than a convention — a type that projects to itself (the
      # default, and value-preserving types like FilteredHashMap/Static) simply
      # doesn't reduce and falls through to its #subtype_of? leaf, instead of
      # recursing into subtype?(self, b) forever.
      ai = a.subtype_identity
      return subtype?(ai, b) unless ai.equal?(a)

      bi = b.subtype_identity
      return subtype?(a, bi) unless bi.equal?(b)

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
        return nil if merged.nil?
        return Types::Never if merged.equal?(Constraint::EMPTY) # unsatisfiable clause ⇒ bottom

        AttributeValueMatch.new(left.type, left.attr_name, merged)
      when And
        # A conjunct that folds to Never makes the whole And uninhabitable ⇒ Never.
        if (right = merge_attribute_into(left.children[1], avm))
          right.is_a?(NeverClass) ? right : And.new(left.children[0], right)
        elsif (leftc = merge_attribute_into(left.children[0], avm))
          leftc.is_a?(NeverClass) ? leftc : And.new(leftc, left.children[1])
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

    # Intersect two attribute-constraint values into a single value, `nil` to keep
    # the two clauses stacked, or `Constraint::EMPTY` when the overlap is provably
    # empty (the caller turns that into Never). Raw Ranges/Sets intersect to their
    # (possibly narrower, possibly empty) overlap via Constraint.merge_matchers; a
    # Plumb-typed value reduces only by subsumption — keeping the narrower — and
    # otherwise stays stacked (intersecting two arbitrary Plumb types into one
    # clause isn't representable).
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
      (value_preserving?(right) && subtype?(left, right)) ||
        redundant_record_refinement?(left, right)
    end

    # The record case of `redundant_refinement?`. A HashClass is NOT value-
    # preserving in general — a non-inclusive record drops undeclared keys — so
    # the generic test above never fires for it. `left >> right` (both records)
    # still reduces to `left` when `right` merely re-validates every value `left`
    # produces without dropping or changing anything. Sound sufficient conditions:
    #
    #   - both are plain records (no typed/pattern keys — only literal keys and an
    #     optional `_` catch-all — so key-keeping is decidable);
    #   - the same declared (literal) key set — `right` drops none of `left`'s keys
    #     and requires none `left` lacks;
    #   - `left <= right` — `right`'s fields are supertypes with compatible
    #     optionality, so it rejects nothing `left` emits;
    #   - every `right` field is value-preserving — `right` coerces nothing;
    #   - if `left` carries a catch-all (so it emits arbitrary extra keys), `right`
    #     carries a value-preserving catch-all that covers it — otherwise `right`
    #     would drop or reject those extra keys.
    #
    # Anything short keeps the And (`right` might drop keys or convert values —
    # eg. the front/back coercion `Hash[price: Int] >> Hash[price: Int.build(Money)]`
    # must NOT collapse).
    def redundant_record_refinement?(left, right)
      return false unless left.is_a?(HashClass) && right.is_a?(HashClass)
      return false unless plain_record?(left) && plain_record?(right)
      return false unless same_literal_keys?(left, right)
      return false unless catch_all_preserved?(left, right)
      return false unless subtype?(left, right)

      right.literal_fields.all? { |_key, field| value_preserving?(field) }
    end

    # A record whose only keys are literal names plus an optional `_` catch-all
    # (no typed/pattern keys, whose key-keeping we don't reason about here).
    def plain_record?(hash) = hash.matcher_fields.all? { |key, _| key.catch_all? }

    # Do two records declare the same set of literal key names?
    def same_literal_keys?(left, right)
      lk = left.literal_fields.keys
      rk = right.literal_fields.keys
      lk.size == rk.size && lk.all? { |k| rk.any? { |o| o.eql?(k) } }
    end

    # Does `right` keep and preserve `left`'s catch-all tail (the keys `left` emits
    # beyond its declared ones)? Vacuously true when `left` has no catch-all.
    def catch_all_preserved?(left, right)
      lc = left.catch_all_type
      return true if lc.nil?

      rc = right.catch_all_type
      !rc.nil? && value_preserving?(rc) && subtype?(lc, rc)
    end

    # Join-dual of `reduce_step`: absorption for `a | b`. If one branch's value
    # set is contained in the other's (`a <= b`), the union equals the wider
    # branch (`a ∪ b == b`), so drop the narrower — and `a | a` dedupes. Returns
    # the surviving type, or nil to fall back to `Or.new`.
    #
    # Guarded to VALUE-PRESERVING refinements only. `subtype?` identifies a
    # Function by its OUTPUT type, so `subtype?(String->Integer, Numeric)` is
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

    # The meet (greatest lower bound) of two types — the dual of reduce_union's
    # join. `intersect(a, b)` returns the narrowed type, or nil to fall back to
    # `And.new(a, b)` (a sound runtime intersection: both sides must pass). It
    # only produces `Types::Never` when the intersection is PROVABLY empty
    # (disjoint ranges/sets/classes); when it can't prove emptiness or a subtype
    # relation, it declines (nil) so the caller keeps a runtime And.
    #
    # Consumed by Composable#&.
    def intersect(a, b)
      a = Composable.wrap(a)
      b = Composable.wrap(b)

      return a if a.is_a?(NeverClass) # Never & X == Never
      return b if b.is_a?(NeverClass)
      return b if a.is_a?(AnyClass)   # Any & X == X (top is the meet identity)
      return a if b.is_a?(AnyClass)

      return a if a == b
      return a if subtype?(a, b) # a ⊆ b — meet keeps the narrower a
      return b if subtype?(b, a) # b ⊆ a — keep the narrower b

      # Distribute over unions: (a1 | a2) & b == (a1 & b) | (a2 & b).
      return intersect_union(a, b) if a.is_a?(Or)
      return intersect_union(b, a) if b.is_a?(Or)

      intersect_constraints(a, b) ||
        intersect_containers(a, b) ||
        (disjoint_atomic?(a, b) ? Types::Never : nil)
    end

    # Distribute `&` over a union: intersect each branch with `other`, drop the
    # branches that go Never, and rejoin the survivors with `|`. All-Never ⇒
    # Never. A branch the reducer can't fold becomes a runtime And.
    def intersect_union(union, other)
      parts = union.children.filter_map do |branch|
        m = intersect(branch, other) || And.new(branch, other)
        m unless m.is_a?(NeverClass)
      end
      return Types::Never if parts.empty?

      parts.reduce { |acc, p| acc | p }
    end

    # Intersect two knowable refinements over the SAME base type (Ranges or Sets),
    # reusing Constraint.merge_matchers. An empty overlap (disjoint Ranges, empty
    # Set intersection) is provably empty ⇒ Never; a non-empty overlap rebuilds via
    # Constraint.narrow (`Integer[2..] & Integer[0..100]` == `Integer[2..100]`).
    # Returns nil for anything it can't merge here (different bases, non-Range/Set
    # matchers), leaving the caller to try other strategies.
    def intersect_constraints(a, b)
      return nil unless a.is_a?(Constraint) && b.is_a?(Constraint)
      return nil unless a.base && b.base && a.base == b.base

      merged = Constraint.merge_matchers(a.matcher, b.matcher)
      return nil if merged.nil? # not the same knowable kind, or an incomputable overlap
      return Types::Never if merged.equal?(Constraint::EMPTY) # provably empty ⇒ Never

      Constraint.narrow(a.base, merged)
    end

    # Intersect two covariant containers of the same class (Array/Tuple/HashMap)
    # by intersecting their children pairwise — `Array[A] & Array[B]` ==
    # `Array[A & B]`. Returns nil for non-containers or a class/arity mismatch (the
    # caller then falls back).
    #
    # A `Never` child does NOT necessarily sink the whole container. A Tuple has
    # fixed arity — every position must be filled — so a `Never` element makes it
    # uninhabitable ⇒ `Never`. A homogeneous container (Array/HashMap) can be
    # empty, so `Array[Never]` / `HashMap[K, Never]` are still inhabited (by `[]` /
    # `{}`) and are kept as-is rather than collapsed.
    def intersect_containers(a, b)
      return nil unless container_covariant?(a) && a.instance_of?(b.class)
      return nil if a.children.empty? || a.children.size != b.children.size

      merged = a.children.zip(b.children).map { |x, y| intersect(x, y) || And.new(x, y) }
      return Types::Never if a.is_a?(TupleClass) && merged.any? { |m| m.is_a?(NeverClass) }

      rebuild_container(a, merged)
    end

    def container_covariant?(type)
      type.is_a?(ArrayClass) || type.is_a?(TupleClass) || type.is_a?(HashMap)
    end

    def rebuild_container(type, children)
      case type
      when ArrayClass then type.of(children.first)
      when TupleClass then type.of(*children)
      when HashMap then HashMap.new(children[0], children[1])
      end
    end

    # Are two leaf types provably disjoint? True when NO pair of their underlying
    # Ruby base types is subtype-related — so no value can be an instance of both
    # (`Types::String & Types::Integer` ⇒ Never). Conservative: an unknown base
    # (opaque matcher ⇒ empty base-type list) is NOT provably disjoint, so the
    # caller keeps a runtime And rather than wrongly collapsing to Never.
    def disjoint_atomic?(a, b)
      abt = Plumb.resolve_base_types(a)
      bbt = Plumb.resolve_base_types(b)
      return false if abt.empty? || bbt.empty?

      abt.none? { |x| bbt.any? { |y| class_le?(x, y) || class_le?(y, x) } }
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
      when And then type.children.flat_map { |c| steps(c) }
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
    # TypeCache, a pure structural predicate like #accepted_type. Functions and
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

    # Every node resolves its own #input_type / #output_type (an And does it at
    # construction, an Or maps over its branches), so this is normally a single
    # hop. The loop remains for nodes that delegate through a wrapper chain, and
    # bottoms out when a type is its own io type. Memoized per node in TypeCache
    # (frozen nodes only) — worth it for Or, which allocates a fresh Or of its
    # resolved branches on every call.
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

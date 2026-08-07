# frozen_string_literal: true

require 'plumb/subtyping'

module Plumb
  # THE REWRITE RULES — the optimisation pass over the type AST.
  #
  # The operators do not build the tree you wrote; they build an equivalent one with
  # the provably-redundant runtime work removed. `Integer[0..100] >> Integer[0..]`
  # validates `::Integer` once; `Integer | Numeric` collapses to `Numeric`;
  # `String[/a/] | String[/b/]` checks `String` once and branches on the suffixes.
  #
  # A different kind of thing from {Plumb::Subtyping}: the relation ANSWERS questions
  # about types, these REWRITE one AST into another. Keeping them apart makes the
  # dependency one-way (Optimizer -> Subtyping, never back).
  #
  # Runs EAGERLY at build time, not as a deferred pass, because reductions are
  # observable through `#inspect`, `#==` and the visitors — a type's identity is its
  # reduced form, and `(Integer[0..100] >> Integer[0..]) == Integer[0..100]` is a
  # documented property.
  #
  # EVERY RULE MUST PRESERVE, for every input: validity, output value, errors, and
  # execution order. The last is easy to lose and invisible to most tests, since it
  # only shows up when a step has a side effect — which is why absorption and factoring
  # are gated on `#value_preserving?`. spec/invariants_spec.rb asserts all four, order
  # via probes that log each step as it runs.
  #
  # THE RULES, in the order tried:
  #
  #   `left >> right` / `left / right`   reduce_step, then redundant_refinement?
  #                                      (#>> only), else Conjunction.build
  #   `left | right`                     reduce_union, then factor_union,
  #                                      else Disjunction.build
  #
  # reduce_step is itself a ladder: intersection distribution, attribute narrowing,
  # step fusion, refinement re-parenting, and finally boundary absorption.
  #
  # The meet (`#&`) is NOT here — a greatest lower bound is lattice algebra, not a
  # rewrite, so it stays in Subtyping.intersect.
  #
  # DECLINED, not missing: dropping a redundant gate on the LEFT. reduce_step drops one
  # on the right (`f >> Types::String` returns `f`), and the mirror looks equally free —
  # `Types::String >> f` runs the String check twice when `f` declares String as its
  # input, worth 21% of a resolve, or 64% for `Types::UUID::V4 >> a_finder` where a
  # regex ran twice. It was implemented and measured, then backed out: it destroys the
  # shared prefix factor_union hoists, so `(String >> b) | (String >> c) | (String >> d)`
  # goes from one String check to three — 3.7x worse on the rejection path, which is
  # where an enum-like union spends its time. The two rules want opposite things about
  # the same node (absorb the gate vs extract it), and at `>>` time there is no way to
  # know a `|` is coming. Factoring wins the bigger case.
  #
  # #absorb_boundary sits on the other side of that line, and where the check goes is
  # what divides them: it moves a left-hand type into an `Any` input slot only, where
  # there is no gate to drop, so what a union gives up is a step boundary in a chain
  # whose middle step is an untyped callable. Extending it to a TYPED input slot
  # (`Types::String >> (String -> Integer)` -> just the transform) is the declined rule
  # in another form, and would need factor_union taught to unfold a value-preserving
  # input slot back into a step before it could pay.
  module Optimizer
    module_function

    # The full rule set for `left >> right`. Always returns a node.
    #
    # @param left [Composable]
    # @param right [Composable]
    # @return [Composable]
    def rewrite_step(left, right)
      reduce_step(left, right) ||
        (redundant_refinement?(left, right) ? left : Conjunction.build(left, right))
    end

    # For `left / right` — the escape hatch, and the refinement builders (#[], #where,
    # #value) that route through it.
    #
    # STRUCTURAL REDUCTION ONLY: absorption is deliberately skipped, because `#/` exists
    # to assert a narrowing the checker cannot prove, and dropping it as "already
    # guaranteed" would discard the cast the caller asked for. reduce_step still removes
    # a duplicated type gate, which is pure bookkeeping.
    #
    # @param left [Composable]
    # @param right [Composable]
    # @return [Composable]
    def rewrite_refinement(left, right)
      reduce_step(left, right) || Conjunction.build(left, right)
    end

    # The full rule set for `left | right`. Always returns a node.
    #
    # @param left [Composable]
    # @param right [Composable]
    # @return [Composable]
    def rewrite_union(left, right)
      reduce_union(left, right) ||
        factor_union(left, right) ||
        Disjunction.build(left, right)
    end

    # Rung-1 structural reduction of `left >> right` — the ladder tried before
    # absorption into a Conjunction: intersection distribution, attribute narrowing,
    # step fusion, refinement re-parenting, boundary absorption. Each is a method or a
    # commented block below, in that order. Returns the reduced type, or `nil` to fall
    # back to `Conjunction.build`.
    def reduce_step(left, right)
      # A refinement narrows by each conjunct in turn: `left / (b ∧ c)` is
      # `(left / b) / c`. Being an Intersection IS the condition — it is only
      # built when both sides preserve the value — so no runtime value-preservation
      # test is needed here. A composition (And) carries a transform, is a barrier,
      # and falls through to the Constraint check below, which bails.
      if right.is_a?(Intersection)
        l = reduce_step(left, right.children[0]) || Conjunction.build(left, right.children[0])
        return reduce_step(l, right.children[1]) || Conjunction.build(l, right.children[1])
      end

      # An attribute constraint intersects into `left`'s clause on the same
      # attribute — like Constraint.narrow intersects Ranges — or stacks on when
      # there is none. `String.where(size: 0..40) / .where(size: 10..100)` ->
      # `.where(size: 10..40)`, one `String` check.
      return narrow_attribute(left, right) if right.is_a?(AttributeValueMatch)

      # Two adjacent converting steps whose boundary is provable at build time
      # fuse into one node: `(A -> B) >> (B -> C)` becomes `(A -> C)` running
      # both fns, dropping the redundant out/in checks between them. fuse_with
      # carries its own subtype proof, so it is sound from #>> and #/ alike.
      if (fused = left.fuse_with(right))
        return fused
      end

      reparent_refinement(left, right) || absorb_boundary(left, right)
    end

    # When `right` is a refinement (a `Constraint` chain) whose ROOT is a base-type
    # (Module) gate that `left`'s output already guarantees, that gate is a duplicated
    # runtime check: re-parent `right`'s refinement matchers onto `left` and drop it.
    # Nil when it declines, which leaves the pair to the absorption rung.
    #
    # Keyed on the root TYPE only (`Subtyping.subtype?(left_output, root)`), NOT on matcher
    # values — so `Integer[0..100] >> Integer[-10..110]` becomes
    # `Integer[0..100][-10..110]` (the `-10..110` range is preserved), not the
    # value-subsumed `Integer[0..100]` (that would be rung 2).
    #
    #   matchers=[-10..110], root=Constraint(::Integer), left guarantees Integer
    #   => Constraint(-10..110, base: Integer[0..100]) == Integer[0..100][-10..110]
    #
    # Degenerate `left >> Integer` (`matchers == []`) returns `left` — a pure
    # redundant type gate removed.
    def reparent_refinement(left, right)
      return nil unless right.is_a?(Constraint)

      matchers = [] # innermost-first, excludes the root gate
      node = right
      while node.is_a?(Constraint) && node.base
        matchers.unshift(node.matcher)
        node = node.base
      end
      root = node
      return nil unless root.is_a?(Constraint) && SemanticMatcher.nominal?(root.matcher)
      return nil unless Subtyping.subtype?(Subtyping.resolved_output(left), root)

      # Stack right's refinements onto left; Constraint.narrow intersects Ranges
      # so `Integer[0..100] >> Integer[0..]` collapses to `Integer[0..100]`.
      matchers.reduce(left) { |acc, m| Constraint.narrow(acc, m) }
    end

    # LAST RUNG. A typed step runs its boundary types as steps, so a plain type next
    # to one can move into the matching slot: `Types::Integer >> a_proc >>
    # Types::Float` becomes the single `(Integer -> Float)` instead of a three-node
    # chain with an `Any` hop in the middle. The node owns the conditions (see
    # Function#absorb_output / #absorb_input) and at most one side can accept, since
    # each requires the OTHER side to be a value-preserving type — which a typed step
    # never is, and a seam between two of those is #fuse_with's.
    #
    # Last in the ladder, so a pair another rule reduces gets that reduction instead:
    # `#[]` on a transform re-parents (`String.transform(:to_i)[0..10]`), and a
    # redundant gate is dropped rather than absorbed.
    def absorb_boundary(left, right)
      left.absorb_output(right) || right.absorb_input(left)
    end

    # Narrow `left` by attribute constraint `avm`: intersect it into `left`'s
    # existing clause on the same attribute+base type (mirroring how
    # Constraint.narrow intersects Range matchers), or stack it on when there is
    # no such clause. Always reduces (never bails) — an AVM is a value-narrowing
    # refinement, so there is no duplicated type gate to keep it apart.
    def narrow_attribute(left, avm)
      merge_attribute_into(left, avm) || Conjunction.build(left, avm)
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
      when Conjunction
        # A conjunct that folds to Never makes the whole node uninhabitable ⇒ Never.
        if (right = merge_attribute_into(left.children[1], avm))
          right.is_a?(NeverClass) ? right : Conjunction.build(left.children[0], right)
        elsif (leftc = merge_attribute_into(left.children[0], avm))
          leftc.is_a?(NeverClass) ? leftc : Conjunction.build(leftc, left.children[1])
        end
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
        return a if Subtyping.value_subtype?(a, b)
        return b if Subtyping.value_subtype?(b, a)

        nil
      else
        Constraint.merge_matchers(a, b)
      end
    end

    # Two same-attribute clauses may merge when their base types are subtype-
    # comparable — so a clause built on `String` and one built on the accumulated
    # `String.where(size: …)` (as chained `#where` produces) still fold together.
    def compatible_base?(a, b)
      a == b || Subtyping.subtype?(a, b) || Subtyping.subtype?(b, a)
    end

    # In `left >> right`, is `right` a no-op that `left` already guarantees?
    # True when `right` preserves values AND every value `left` produces already
    # satisfies it (`left <= right`), so `right` can neither reject nor change
    # them — eg. `String.where(size: 3..10) >> String.where(size: 0..)` drops the
    # vacuous `size: 0..`. This is what reduce_step does for a Constraint chain,
    # generalized to any value-preserving refinement (a `where`/AVM And, a nested
    # Or). It tests REAL subsumption via Subtyping.subtype?, not check_composable!'s type-
    # compat check — a value-narrowing refinement (AVM) opts out of the latter
    # (its #input_type is Any), so check_composable! can't tell it apart.
    def redundant_refinement?(left, right)
      # `right` is the dropped side (kept: left). Don't drop it if it carries
      # wrapper identity Subtyping.subtype? now sees through — unless it equals left,
      # where left already IS that identity. eg. `String[EMAIL] >> Types::Email`
      # keeps the And so the :email node (and its JSON-schema format) survives.
      if Subtyping.value_preserving?(right) && Subtyping.subtype?(left, right) &&
         (left == right || !Subtyping.identity_wrapper?(right))
        return true
      end

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
      return false unless Subtyping.subtype?(left, right)

      right.literal_fields.all? { |_key, field| Subtyping.value_preserving?(field) }
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
      !rc.nil? && Subtyping.value_preserving?(rc) && Subtyping.subtype?(lc, rc)
    end

    # Join-dual of `reduce_step`: absorption for `a | b`. If one branch's value set
    # is contained in another's, the union equals the wider branch
    # (`a ∪ b == b` when `a <= b`), so the narrower is dropped — and duplicate
    # branches dedupe. Returns the surviving type, or nil when nothing can go.
    #
    # A JOIN IS N-ARY. `A | B | C` is stored as a nested pair but means one flat branch
    # set, so absorption has to see all of it — comparing only the two operands makes
    # the result depend on the order they were written:
    #
    #   Numeric | String | Integer   =>  Numeric | String        (Integer absorbed)
    #   Integer | String | Numeric   =>  (Integer | String) | Numeric
    #
    # Both accept the same values, but the second keeps `Integer` even though
    # `Integer <= Numeric`, because `subtype?(Union(Integer, String), Numeric)` requires
    # EVERY branch to be within Numeric. The redundant branch then costs a failed match
    # on every value falling through to it.
    #
    # So flatten, absorb across the set, re-fold. Order among survivors is preserved —
    # a join is commutative, and keeping it stable avoids churning `#inspect` and a
    # JSON Schema's `anyOf` order.
    def reduce_union(a, b)
      branches = union_branches(a) + union_branches(b)
      survivors = absorb_branches(branches)
      return nil if survivors.size == branches.size # nothing to drop — leave the pair alone
      return survivors.first if survivors.size == 1

      survivors.drop(1).reduce(survivors.first) do |acc, branch|
        factor_union(acc, branch) || Disjunction.build(acc, branch)
      end
    end

    # ONLY Union, never Or: a choice is left-biased and its branches may convert, so its
    # order is semantic and dropping one is not a type-level decision.
    def union_branches(type)
      type.is_a?(Union) ? type.children.flat_map { |c| union_branches(c) } : [type]
    end

    # Drop every branch another one already covers, keeping first-seen order.
    def absorb_branches(branches)
      branches.each_with_object([]) do |candidate, survivors|
        next if survivors.any? { |s| absorbs?(s, candidate) }

        survivors.reject! { |s| absorbs?(candidate, s) }
        survivors << candidate
      end
    end

    # Does `wider` cover `narrower`, such that dropping `narrower` changes nothing?
    #
    # Guarded to VALUE-PRESERVING branches: `subtype?` identifies a Function by its
    # OUTPUT type, so `subtype?(String->Integer, Numeric)` holds even though that branch
    # accepts Strings a bare Numeric rejects, and absorbing would drop a coercion.
    # Identical branches dedupe regardless — the survivor IS the dropped node.
    def absorbs?(wider, narrower)
      return true if wider == narrower
      return false unless Subtyping.value_preserving?(wider) && Subtyping.value_preserving?(narrower)
      # Never absorb across a wrapper: subtype? sees through Policy/Metadata/Node, so
      # the drop would lose the identity one carries (eg. `Types::Email |
      # Types::String` must keep both). @see Subtyping.identity_wrapper?
      return false if Subtyping.identity_wrapper?(wider) || Subtyping.identity_wrapper?(narrower)

      Subtyping.subtype?(narrower, wider)
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

      inner = Disjunction.build(rebuild(sa.drop(k)), rebuild(sb.drop(k)))
      Conjunction.build(rebuild(sa.take(k)), inner).as_node(:refined_union)
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
      when Conjunction then type.children.flat_map { |c| steps(c) }
      when Constraint then type.base ? steps(type.base) + [Constraint.new(type.matcher)] : [type]
      else [type]
      end
    end

    # Length of the longest leading run of steps the two lists agree on AND that
    # is value-preserving — the sound-to-factor shared prefix.
    def common_step_prefix(sa, sb)
      max = sa.size < sb.size ? sa.size : sb.size
      i = 0
      i += 1 while i < max && sa[i] == sb[i] && Subtyping.value_preserving?(sa[i])
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
        Conjunction.build(left, right)
      end
    end
  end
end

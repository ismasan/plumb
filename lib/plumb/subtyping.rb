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
    # This engine knows ONLY the TYPE algebra — meet (Intersection), union (Or),
    # and the top type (AnyClass) — plus one projection: a node that CONVERTS is
    # replaced by what it produces (#subtype_identity, which Function,
    # Implementation and the And composition all implement). So an execution node
    # is never reasoned about structurally; it is reduced to a type first. That
    # separation is what keeps the relation sound: applying the meet rule to a
    # composition would put a converting chain under its own input type.
    #
    # Everything else (atomic matchers, covariant containers, Hash width/depth,
    # custom types) is decided by the type's own #subtype_of? leaf hook (see
    # Composable). It never calls #<= (which would recurse back here).
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

      # Transparent wrappers (Policy/Metadata/Node) only re-label the type they
      # delegate to — for the subtype relation they ARE the wrapped type, just
      # as they are for #accepted_type.
      ua = unwrap_transparent(a)
      ub = unwrap_transparent(b)
      return subtype?(ua, ub) unless ua.equal?(a) && ub.equal?(b)

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
      # Joins. The rule is the same for a choice and a union: a branch that
      # converts was already projected onto its output by #subtype_identity, so
      # by here every branch is a type either way.
      return a.children.all? { |m| subtype?(m, b) } if a.is_a?(Disjunction) # (A|B) <= C
      return b.children.any? { |m| subtype?(a, m) } if b.is_a?(Disjunction) # A <= (B|C)

      # Meets: the longer the Intersection chain, the narrower. This rule applies
      # ONLY to a genuine intersection, where both sides describe the same value.
      # A sequential composition (And) is a morphism and was already projected onto
      # what it produces by the #subtype_identity reduction above — applying the
      # meet rule to it would make a converting chain a subtype of its own INPUT
      # type, and so a subtype of two disjoint types at once.
      return b.children.all? { |bb| subtype?(a, bb) } if b.is_a?(Intersection) # a <= (b1 ∧ b2)
      return a.children.any? { |aa| subtype?(aa, b) } if a.is_a?(Intersection) # (a1 ∧ a2) <= b

      # `a` decides via its #subtype_of? leaf; if it can't (it doesn't know about
      # `b`), `b` may claim `a` via #supertype_of? — the mirror hook for
      # supertype-driven relations like Interface duck-typing.
      a.subtype_of?(b) || b.supertype_of?(a)
    end

    # `a` is STRICTLY narrower than `b` — a subtype, and not merely equivalent
    # to it. The named form of `Composable#<`, usable where the operators are
    # not (`a` may be a raw struct Class, where `<` means Ruby ancestry — see
    # Plumb::Attributes).
    def strict_subtype?(a, b) = subtype?(a, b) && !subtype?(b, a)

    # `a` and `b` describe the same values — mutual subtypes.
    def equivalent?(a, b) = subtype?(a, b) && subtype?(b, a)

    # A leaf type whose single child is a raw (non-Composable) Ruby MATCHER — eg.
    # Constraint, ValueClass. These bottom out in #atomic_subtype? rather than
    # recursing.
    #
    # A StaticClass looks the same shape but is excluded: its child is the value it
    # PRODUCES, not a matcher it compares against (it accepts any input), so
    # comparing the two children as matchers relates the wrong things —
    # `Types::Value[5] <= Types::Static[5]` would hold, and via `Static[5] <=
    # Types::Integer` that breaks transitivity. Static answers for itself instead
    # (see StaticClass#subtype_of?).
    def atomic?(type)
      type.respond_to?(:children) &&
        type.children.size == 1 &&
        !type.children.first.is_a?(Composable) &&
        !type.is_a?(StaticClass)
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
        # `Regexp#===` coerces, so a pattern matches Symbols as well as Strings
        # (`/x/ === :xyz`). It is a subtype of a class only if BOTH are.
        when ::Regexp then class_le?(::String, rm) && class_le?(::Symbol, rm)
        when ::Set then lm.all? { |e| rm === e }    # Set[1,2,3] <= Integer
        # A literal matches by Ruby's `==`, which for numerics crosses their
        # classes — `Types::Value[5]` accepts `5`, `5.0`, `5r` and `BigDecimal('5')`
        # alike. So a numeric literal describes Numeric, and is confined to Integer
        # only if Numeric itself is. (A Static is different: it PRODUCES one
        # concrete object rather than matching a set — see StaticClass#subtype_of?.)
        when ::Numeric then class_le?(::Numeric, rm)
        else rm === lm                              # value 'a' <= String
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
        # `Set#===` is `#include?`, which tests `eql?` — so a Set holds ONE numeric
        # spelling, not every value `== lm`. `Types::Value[5]` accepts `5.0`, which
        # `Set[1, 5]` rejects.
        when ::Numeric then false
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

    # Is every value a Range matches an instance of `klass`?
    #
    # BOTH endpoints have to be instances: reading only one accepts
    # `(1..2.5) <= Integer` and `(1.5..3) <= Float`, though the other endpoint
    # matches values of a different class.
    #
    # Note this reads a numeric range as describing its endpoints' class, matching
    # how a numeric LITERAL is read (see #atomic_subtype?) — `(1..10) === 2.5` is
    # true, so both are the same open question about numeric `==` crossing classes.
    def range_in_class?(range, klass)
      ends = [range.begin, range.end].compact
      return false if ends.empty?

      ends.all? { |e| e.is_a?(klass) }
    end

    # Is `inner` contained in `outer`? Endpoint containment, honouring
    # `#exclude_end?` on BOTH sides — `cover?` alone would reject `(1...5)` inside
    # `(0...5)` for an endpoint (`5`) that `inner` does not actually include.
    # Ruby has no exclusive BEGIN, so the low end stays a plain `cover?`.
    #
    # Conservative where containment needs discreteness: `(1...5) <= (0..4)` stays
    # false, since `4.5` separates them for a non-integer base.
    def range_in_range?(inner, outer)
      lo_ok = outer.begin.nil? || (!inner.begin.nil? && outer.cover?(inner.begin))
      lo_ok && range_end_within?(inner, outer)
    end

    def range_end_within?(inner, outer)
      return true if outer.end.nil?
      return false if inner.end.nil?

      cmp = inner.end <=> outer.end
      return false if cmp.nil? # incomparable endpoints prove nothing

      # `inner` reaches its end while `outer` stops short of the same value, so
      # inner's end must fall strictly inside. Every other combination — both
      # exclusive, both inclusive, or inner exclusive inside an inclusive outer —
      # is satisfied by `<=`.
      if !inner.exclude_end? && outer.exclude_end?
        cmp.negative?
      else
        cmp <= 0
      end
    end

    # Regexps are equal when they match the same strings. `#source` alone is not
    # that: `i`, `m` and `x` change what a pattern accepts (`/a/i` matches `'A'`,
    # `/a/` does not), and `#options` is where they live.
    def regex_equal?(a, b)
      a.is_a?(::Regexp) && b.is_a?(::Regexp) && a.source == b.source && a.options == b.options
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

    # The meet (greatest lower bound) of two types — the dual of
    # Optimizer.reduce_union's join. This is lattice algebra rather than a
    # rewrite, which is why it stayed here when the rules moved out. `intersect(a, b)` returns the narrowed type, or nil to fall back to
    # `Conjunction.build(a, b)` (a sound runtime intersection: both sides must pass). It
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

      # The subsumption drops below are sound only when BOTH sides preserve the
      # value — the same guard, for the same reason, as Optimizer.reduce_union.
      # `subtype?` identifies a converting node by its OUTPUT type, so any two
      # `String -> Integer` transforms are mutual subtypes no matter what they
      # compute; dropping one would silently discard a conversion the caller asked
      # for (`to_i & size` returned just `to_i`). Only when neither side alters the
      # value does `subtype?` describe the accepted input domain, which is what
      # makes keeping the narrower side behaviour-preserving.
      #
      # Also skipped when either side is a transparent wrapper: subtype? sees
      # through it, but dropping it loses the identity it carries (see
      # #identity_wrapper?). eg. `Types::Integer & doubler.metadata(...)` keeps both.
      if value_preserving?(a) && value_preserving?(b) &&
         !identity_wrapper?(a) && !identity_wrapper?(b)
        return a if subtype?(a, b) # a ⊆ b — meet keeps the narrower a
        return b if subtype?(b, a) # b ⊆ a — keep the narrower b
      end

      # Distribute over unions: (a1 | a2) & b == (a1 & b) | (a2 & b).
      return intersect_union(a, b) if a.is_a?(Disjunction)
      return intersect_union(b, a) if b.is_a?(Disjunction)

      intersect_constraints(a, b) ||
        intersect_literals(a, b) ||
        intersect_containers(a, b) ||
        (disjoint_atomic?(a, b) ? Types::Never : nil)
    end

    # Distribute `&` over a union: intersect each branch with `other`, drop the
    # branches that go Never, and rejoin the survivors with `|`. All-Never ⇒
    # Never. A branch the reducer can't fold becomes a runtime And.
    def intersect_union(union, other)
      parts = union.children.filter_map do |branch|
        m = intersect(branch, other) || Conjunction.build(branch, other)
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

    # Two literals meet as their singleton sets: distinct values share no
    # inhabitant, so the meet is provably empty ⇒ Never (`Value['a'] &
    # Value['b']`). Equal values need no answer here — #intersect's `a == b`
    # dedupe already folded them — so this only ever returns Never or nil.
    #
    # Decided by `==`, the same test a literal match itself makes, so
    # equality that crosses Ruby classes is honoured: `Value[5] & Value[5.0]` is
    # NOT disjoint, because `5 == 5.0`. That is also why literals can't be told
    # apart by base type — declaring `Value[5]`'s base to be Integer would make
    # it disjoint from Float and wrongly sink `Value[5] & Types::Float` — and so
    # why this reasons over values instead of routing through #disjoint_atomic?.
    #
    # Runs after #intersect_constraints, so two literals over the same base reach
    # here only once Constraint.merge_matchers has declined them (it merges
    # Ranges and Sets, not literals).
    def intersect_literals(a, b)
      av = literal_value(a)
      bv = literal_value(b)
      return nil if Undefined.equal?(av) || Undefined.equal?(bv)

      av == bv ? nil : Types::Never
    end

    # The single value a node matches by equality, or `Undefined` for a node that
    # matches more than one (so a caller can't mistake a membership test for a
    # literal). Covers both spellings of a literal — `Types::Value['a']` and
    # `Types::String['a']` are equally provably disjoint from `'b'` — but checks
    # the two differently: a ValueClass matches by `==` whatever it holds, so any
    # value qualifies, while a Constraint matches by `===`, so only the kinds
    # whose `#===` IS `#==` do (see Constraint#literal?). A bare `Types::Value`
    # already holds Undefined, which reads as "no literal" here.
    def literal_value(node)
      case node
      when ValueClass then node.children.first
      when Constraint then node.literal? ? node.matcher : Undefined
      else Undefined
      end
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

      merged = a.children.zip(b.children).map { |x, y| intersect(x, y) || Conjunction.build(x, y) }
      return Types::Never if a.is_a?(TupleClass) && merged.any? { |m| m.is_a?(NeverClass) }

      a.with_children(merged)
    end

    # The containers that are covariant in their children — the ones
    # #intersect_containers may meet pairwise. NOT the same set as the nodes
    # answering #with_children, which is much wider (see Plumb::NodeMapper).
    def container_covariant?(type)
      type.is_a?(ArrayClass) || type.is_a?(TupleClass) || type.is_a?(HashMap)
    end

    # Map a container's children through `blk` and rebuild it around the results —
    # the shared rule behind every covariant container's #accepted_type and
    # #output_type. Kept as an alias so those call sites read in terms of this
    # module; the traversal and its identity guard live in ONE place, because every
    # rewrite pass depends on an untouched subtree coming back `equal?`.
    #
    # @param type [Composable] a container responding to #with_children
    # @yieldparam child [Composable]
    # @return [Composable] `type` itself, or a rebuilt container
    def map_children(type, &blk) = NodeMapper.map_children(type, &blk)

    # Are two leaf types provably disjoint? True when NO pair of their underlying
    # Ruby base types is subtype-related — so no value can be an instance of both
    # (`Types::String & Types::Integer` ⇒ Never). Conservative: an unknown base
    # (opaque matcher ⇒ empty base-type list) is NOT provably disjoint, so the
    # caller keeps a runtime And rather than wrongly collapsing to Never.
    def disjoint_atomic?(a, b)
      # Only judge two nodes that both return their input unchanged.
      #
      # "No value satisfies both" is the right question for a genuine meet, where
      # each side describes the SAME value. It is the wrong question everywhere
      # else, and Plumb.resolve_base_types answers about what a node PRODUCES: a
      # Function reports its output type, a Static the class of the fixed value it
      # returns whatever its input, a Not the very classes it excludes. Judging
      # those sinks an inhabited intersection to Never — `Types::Integer &
      # Types::Integer.transform(::String, &:to_s)` accepts every Integer, and
      # `Types::String & Types::Not[Types::Integer]` accepts every String.
      #
      abt = stable_domain(a)
      bbt = stable_domain(b)
      return false if abt.nil? || bbt.nil?

      abt.none? { |x| bbt.any? { |y| class_le?(x, y) || class_le?(y, x) } }
    end

    # The Ruby classes `type` accepts, but ONLY when they are also the classes it
    # produces — ie. the node NARROWS one domain rather than moving between two.
    # nil for anything else, including an unknown domain.
    #
    # That distinction is what makes #disjoint_atomic? answerable. "No value
    # satisfies both" is a question about a single domain, so it can only be asked
    # of a node that has one. A converting node has two, and Plumb.resolve_base_types
    # reports only the produced side — which is how `Types::Integer &
    # Types::Integer.transform(::String, &:to_s)` came to look disjoint (Integer vs
    # String) though its And accepts every Integer. A Static reports the class of
    # the value it emits regardless of input, and a Not reports the very classes it
    # excludes; neither has a domain to compare either.
    #
    # Declining here costs only precision: the caller keeps a runtime intersection
    # where it might have proved Never. That matches what `&` already does for a
    # converting side — Conjunction.build keeps both — while a wrong Never discards
    # the whole composition.
    def stable_domain(type)
      accepted = Plumb.resolve_base_types(accepted_type(type))
      return nil if accepted.empty?

      accepted == Plumb.resolve_base_types(resolved_output(type)) ? accepted : nil
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

    # Does `type` carry identity beyond its value semantics — a policy name,
    # user metadata, or a visitor node_name — i.e. is it (wrapped in) a
    # transparent Policy/Metadata/Node? `subtype?` sees THROUGH such wrappers
    # (Policy(X) <= Y iff X <= Y), which is right for the subsumption relation
    # but means a reduction that DROPS one in favour of a subtype-equal type
    # would silently lose that identity. So the reductions (this module's
    # #intersect, and Optimizer.reduce_union / .redundant_refinement?) refuse to
    # drop one — except when the two are equal, where the survivor already IS
    # that identity.
    def identity_wrapper?(type)
      !unwrap_transparent(type).equal?(type)
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

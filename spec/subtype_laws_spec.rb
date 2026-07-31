# frozen_string_literal: true

require 'spec_helper'
require 'set'

# PROPERTY LAWS relating the TYPE ALGEBRA to the RUNTIME.
#
# spec/invariants_spec.rb pins what `<=` currently answers (a snapshot) and the
# lattice laws it must obey (reflexivity, transitivity, top, bottom). Those are
# statements about the relation on its own terms: they can all hold while the
# relation says something the data flatly contradicts.
#
# This file closes that gap. Every law here is a statement about ACCEPTED VALUES,
# checked by running `#resolve` over a witness corpus. `subtype?(a, b)` claims
# "every value `a` describes, `b` describes too" — so if some witness passes `a`
# and fails `b`, the relation is wrong about the data, whatever the algebra says.
#
# That matters because `<=` is not advisory. Four consumers act on it, and each
# turns a wrong verdict into wrong VALIDATION:
#
#   Optimizer.reduce_step / redundant_refinement?  deletes a runtime check
#   Optimizer.reduce_union                         drops a union branch
#   Subtyping.intersect                            drops a meet operand
#   Subtyping.check_composable!                    admits an always-failing chain
#
# So the composition laws (JOIN / MEET / SEQUENCE below) are the ones with teeth:
# they catch a bad verdict at the point where it has already changed behaviour.
#
# RULES OF ENGAGEMENT
#
#   - These laws are an ORACLE, not a snapshot. There is deliberately no
#     allowlist to regenerate: a failure means a type's declared relation and its
#     `#call` disagree, and the fix belongs in the type, not here.
#
#   - Each law reports EVERY violating pair with the concrete witness value, so
#     one run enumerates the whole class of failure rather than the first case.
#
#   - Witnesses are compared BY POSITION, never by `==`. `5 == 5.0` in Ruby, so
#     an accepted-set built with `Array#include?` would silently conflate exactly
#     the cross-class equality some of these laws exist to test.
#
#   - A specimen whose `#resolve` raises is treated as REJECTING that witness, so
#     one raising type doesn't contaminate the other laws. RESOLVE TOTALITY below
#     is what reports the raise.
#
# ADDING A SPECIMEN: prefer one that is structurally unlike what is already
# there — a wrapper, a negation, a recursive type, an open record. The laws are
# only as strong as the grid, and a near-duplicate specimen buys nothing.
RSpec.describe 'subtype relation vs runtime behaviour' do
  # ---------------------------------------------------------------------------
  # Witness corpus
  # ---------------------------------------------------------------------------

  # A stable stand-in for "an object satisfying no matcher in the grid" — a bare
  # Object.new would inspect as a different address on every run, making failure
  # output unstable.
  OPAQUE = Object.new
  def OPAQUE.inspect = '#<opaque>'
  OPAQUE.freeze

  WITNESSES = [
    Plumb::Undefined,
    nil, true, false,
    0, 1, 2, 5, 10, 18, 50, 99, 100, 101, -1,
    5.0, 2.5, 99.5, 100.0,
    'a', 'A', 'ab', 'abcd', '', '42', 'a@b.com',
    :a, :xyz,
    [], [1], [1, 2], ['a'], [1, 'a'],
    {}, { a: 1 }, { a: 'x' }, { a: 1, b: 'x' }, { name: 'a', age: 1 },
    { name: 'a', age: 'x' }, { 'id_1' => 'x' }, { v: 1, n: nil },
    (1..3), ::Set[1, 2], OPAQUE
  ].freeze

  # ---------------------------------------------------------------------------
  # Specimen grid
  # ---------------------------------------------------------------------------

  # Recursive records, to exercise Deferred through the relation rather than only
  # through #resolve. IntList and StrList are structurally DIFFERENT types; any
  # law that finds them interchangeable has found a bug.
  IntList = Types::Hash[v: Types::Integer, n: Types::Nil | Types::Any.defer { IntList }]
  StrList = Types::Hash[v: Types::String,  n: Types::Nil | Types::Any.defer { StrList }]

  PersonStruct = Types::Data[name: Types::String, age: Types::Integer]

  # A refinement stacked on a CONVERSION. `#[]` re-parents into a Constraint whose
  # base is the transform, so this node converts while presenting as a matcher.
  COERCE_AGE = Types::String.transform(::Integer, :to_i)[0..150]

  SPECIMENS = {
    # tops, bottoms, and the odd one out
    'Any' => Types::Any,
    'Never' => Types::Never,
    'Undefined' => Types::Undefined,
    'Interface[]' => Types::Interface[],

    # scalars
    'String' => Types::String,
    'Integer' => Types::Integer,
    'Numeric' => Types::Numeric,
    'Float' => Types::Float,
    'Symbol' => Types::Symbol,
    'Nil' => Types::Nil,
    'Boolean' => Types::Boolean,

    # refinements — ranges (inclusive AND exclusive: range_in_range? must respect
    # #exclude_end?, and Constraint.intersect_ranges already does)
    'Integer[0..100]' => Types::Integer[0..100],
    'Integer[10..]' => Types::Integer[10..],
    'Integer[0...100]' => Types::Integer[0...100],
    'Integer[1...5]' => Types::Integer[1...5],
    'Integer[0...5]' => Types::Integer[0...5],

    # refinements — regexp. Options are semantically load-bearing, so /a/ and
    # /a/i must NOT be interchangeable.
    'String[/a/]' => Types::String[/a/],
    'String[/a/i]' => Types::String[/a/i],
    'String.where(size: 1..3)' => Types::String.where(size: 1..3),

    # literals, both spellings. ValueClass matches by `==`, so its inhabitants are
    # `{v | v == 5}` — which in Ruby includes 5.0.
    'Value[5]' => Types::Value[5],
    'Value[5.0]' => Types::Value[5.0],
    'Any[5]' => Types::Any[5],
    'Static[5]' => Types::Static[5],

    # joins and meets
    'String|Integer' => Types::String | Types::Integer,
    'Integer.nullable' => Types::Integer.nullable,
    'Integer[0..100]&Integer[10..]' => Types::Integer[0..100] & Types::Integer[10..],

    # negation — must be CONTRAvariant
    'Not[Integer]' => Types::Not[Types::Integer],
    'Not[Numeric]' => Types::Not[Types::Numeric],

    # transparent wrappers. `subtype?` sees through these, and the reductions must
    # not treat two wrappers of DISJOINT types as interchangeable.
    'String.present' => Types::String.present,
    'Integer.present' => Types::Integer.present,
    'Integer[1..10].metadata' => Types::Integer[1..10].metadata(lab: 'x'),
    'Integer[100..200].metadata' => Types::Integer[100..200].metadata(lab: 'x'),
    'defer{Integer}' => Types::Any.defer { Types::Integer },
    'defer{String}' => Types::Any.defer { Types::String },

    # containers
    'Array[Integer]' => Types::Array[Types::Integer],
    'Array[Numeric]' => Types::Array[Types::Numeric],
    'Tuple[Integer,String]' => Types::Tuple[Types::Integer, Types::String],

    # records: the bare "any Hash" top, closed, open, and pattern-keyed
    'Hash' => Types::Hash,
    'Hash[a:Integer]' => Types::Hash[a: Types::Integer],
    'Hash[a:Numeric]' => Types::Hash[a: Types::Numeric],
    'Hash[a?:Integer]' => Types::Hash[:'a?' => Types::Integer],
    'Hash[_:Integer]' => Types::Hash[_: Types::Integer],
    'Hash[/^id_/:Integer]' => Types::Hash[Types::String[/^id_/] => Types::Integer],
    'HashMap[Symbol,Integer]' => Types::Hash[Types::Symbol, Types::Integer],

    # conversions, and a conversion wearing a matcher's clothes
    'String->Integer' => Types::String.transform(::Integer, :to_i),
    'coerce_age' => COERCE_AGE,

    # A transform whose block returns something other than its declared output.
    # Function#call deliberately validates the produced value rather than trusting
    # the declaration, so the library's defined answer here is an INVALID result —
    # which makes this a fair specimen, and the one that catches a reduction
    # removing that check at a composition seam.
    'String->Integer(lying)' => Types::String.transform(::Integer) { |s| s },

    # A downstream consumer for the transforms above, so a `>>` between two typed
    # steps reaches Function#fuse_with — the seam where a declared output type is
    # trusted instead of checked.
    'Integer->String' => Types::Integer.transform(::String, &:to_s),

    # recursive + struct
    'IntList' => IntList,
    'StrList' => StrList,
    'PersonStruct' => PersonStruct,
    'Hash[name:String,age:Integer]' => Types::Hash[name: Types::String, age: Types::Integer]
  }.freeze

  LABELS = SPECIMENS.keys.freeze

  # ---------------------------------------------------------------------------
  # Probing
  # ---------------------------------------------------------------------------

  # Witness indices `type` accepts, plus the indices where `#resolve` RAISED
  # instead of returning a Result. A raise counts as a rejection for every other
  # law (see RULES OF ENGAGEMENT) and is reported once, by RESOLVE TOTALITY.
  def self.probe(type)
    accepted = Set.new
    raised = {}
    WITNESSES.each_index do |i|
      begin
        result = type.resolve(WITNESSES[i])
      rescue StandardError => e
        raised[i] = "#{e.class}: #{e.message}"
        next
      end
      accepted << i if result.valid?
    end
    [accepted, raised]
  end

  PROBED = SPECIMENS.transform_values { |t| probe(t) }.freeze
  ACCEPTS = PROBED.transform_values(&:first).freeze
  RAISED = PROBED.transform_values(&:last).freeze

  def self.witness(index) = "#{WITNESSES[index].inspect} (#{WITNESSES[index].class})"

  # Name at most a handful of witnesses per violation. One counterexample proves
  # the law broken; a full corpus dump per line buries the next violation.
  def self.witnesses(indices, limit: 4)
    named = indices.to_a.first(limit).map { |i| witness(i) }
    extra = indices.size - named.size
    extra.positive? ? "#{named.join(', ')} (+#{extra} more)" : named.join(', ')
  end

  # `Types::Any` is not a join identity by construction: AnyClass#| is a documented
  # BUILDER shortcut (`Any | X == X`, mirroring `Any[String] == String`), so it
  # deliberately discards the top rather than absorbing. Excluded from the union
  # laws, which would otherwise report a design decision as a bug.
  def self.builder_shortcut?(type) = type.is_a?(Plumb::AnyClass)

  # Build `expr` (a composition), or nil when the checker refuses it. A refused
  # composition is the checker working, not a violation — the laws below only
  # constrain chains that were actually built.
  def self.build
    yield
  rescue Plumb::TypeError
    nil
  end

  def report(violations)
    return if violations.empty?

    raise RSpec::Expectations::ExpectationNotMetError,
          "#{violations.size} violation(s):\n  - #{violations.join("\n  - ")}"
  end

  # ---------------------------------------------------------------------------
  # THE LAWS
  # ---------------------------------------------------------------------------

  # `#resolve` is total: every type turns a value into a Result, and reports a
  # mismatch as an invalid Result rather than by raising. A type that raises can't
  # be composed defensively — the caller has no Result to inspect.
  describe 'RESOLVE TOTALITY' do
    it 'never raises, for any specimen and any witness' do
      violations = LABELS.flat_map do |label|
        RAISED[label].map { |i, err| "#{label}.resolve(#{self.class.witness(i)}) raised #{err}" }
      end

      report(violations)
    end
  end

  # THE central law. `subtype?(a, b)` asserts every value `a` describes is
  # described by `b`; scoped to value-preserving types, where "describes" is
  # exactly "accepts and returns unchanged", that is literally set inclusion.
  #
  # A converting type is excluded because it is deliberately identified by what it
  # PRODUCES, not what it consumes (Subtyping#subtype_identity) — so its accepted
  # set is not what the relation is talking about.
  describe 'SUBTYPE SOUNDNESS' do
    it 'never claims a <= b while b rejects a value a accepts' do
      violations = []
      LABELS.each do |a|
        next unless Plumb::Subtyping.value_preserving?(SPECIMENS[a])

        LABELS.each do |b|
          next if a == b
          next unless Plumb::Subtyping.value_preserving?(SPECIMENS[b])
          next unless Plumb::Subtyping.subtype?(SPECIMENS[a], SPECIMENS[b])

          bad = ACCEPTS[a] - ACCEPTS[b]
          violations << "#{a} <= #{b}, but #{b} rejects: #{self.class.witnesses(bad)}" if bad.any?
        end
      end

      report(violations)
    end
  end

  # Mutual subtypes are the same type as far as the relation can tell, so every
  # reduction is free to swap one for the other. If their accepted sets differ,
  # some reduction will silently change what validates.
  #
  # This is where a node that inherits `Equality#==` while keeping its identity in
  # ivars shows up: `==` compares class + #children, `subtype?` short-circuits on
  # `a == b`, and the wrapper guards never run.
  describe 'EQUIVALENCE' do
    it 'gives mutual subtypes the same accepted set' do
      violations = []
      seen = Set.new
      LABELS.each do |a|
        next unless Plumb::Subtyping.value_preserving?(SPECIMENS[a])

        LABELS.each do |b|
          next if a == b || seen.include?(Set[a, b])
          next unless Plumb::Subtyping.value_preserving?(SPECIMENS[b])
          next unless Plumb::Subtyping.equivalent?(SPECIMENS[a], SPECIMENS[b])

          seen << Set[a, b]
          only_a = ACCEPTS[a] - ACCEPTS[b]
          only_b = ACCEPTS[b] - ACCEPTS[a]
          next if only_a.empty? && only_b.empty?

          violations << "#{a} and #{b} are mutual subtypes, but only #{a} accepts " \
                        "[#{self.class.witnesses(only_a)}] and only #{b} accepts " \
                        "[#{self.class.witnesses(only_b)}]"
        end
      end

      report(violations)
    end
  end

  # `a | b` is a JOIN: Disjunction#call tries `a`, then retries `b` on the
  # original value, so the union accepts everything EITHER branch accepts.
  # Reduction may rewrite the node; it may not shrink that set.
  #
  # Holds for every pair, converting branches included — this is about the values
  # the built node accepts, not about identity.
  describe 'JOIN' do
    it 'never accepts less than either branch' do
      violations = []
      LABELS.each do |a|
        next if self.class.builder_shortcut?(SPECIMENS[a])

        LABELS.each do |b|
          next if a == b

          union = self.class.build { SPECIMENS[a] | SPECIMENS[b] }
          next if union.nil?

          accepted, = self.class.probe(union)
          lost = (ACCEPTS[a] | ACCEPTS[b]) - accepted
          violations << "(#{a} | #{b}) => #{union.inspect} rejects: #{self.class.witnesses(lost)}" if lost.any?
        end
      end

      report(violations)
    end
  end

  # `a & b` is a MEET: it must accept only what BOTH accept.
  #
  # Gated on both sides being value-preserving, because that is exactly when
  # Conjunction.build yields an Intersection. When either side converts it builds
  # an And instead, whose `#call` is SEQUENTIAL (`result.map(@left).map(@right)`,
  # so the right sees the left's OUTPUT) — a pipeline, legitimately not a meet.
  #
  # Note the gate consults `value_preserving?`, so a node that MISREPORTS itself
  # as value-preserving is judged by the meet law it claims to obey.
  describe 'MEET' do
    it 'never accepts what either side rejects' do
      violations = []
      LABELS.each do |a|
        next unless Plumb::Subtyping.value_preserving?(SPECIMENS[a])

        LABELS.each do |b|
          next if a == b
          next unless Plumb::Subtyping.value_preserving?(SPECIMENS[b])

          meet = self.class.build { SPECIMENS[a] & SPECIMENS[b] }
          next if meet.nil?

          accepted, = self.class.probe(meet)
          extra = accepted - (ACCEPTS[a] & ACCEPTS[b])
          violations << "(#{a} & #{b}) => #{meet.inspect} accepts: #{self.class.witnesses(extra)}" if extra.any?
        end
      end

      report(violations)
    end
  end

  # `a >> b` runs `a` first, and `Result#map` short-circuits on an invalid result,
  # so the chain CANNOT accept what `a` rejects. Unconditional — no gate, no
  # exceptions.
  #
  # This is the law that catches a reduction removing a check it believed
  # redundant: composing must never turn an invalid value into a valid one.
  describe 'SEQUENCE' do
    it 'never accepts what its left side rejects' do
      violations = []
      LABELS.each do |a|
        LABELS.each do |b|
          next if a == b

          chain = self.class.build { SPECIMENS[a] >> SPECIMENS[b] }
          next if chain.nil?

          accepted, = self.class.probe(chain)
          widened = accepted - ACCEPTS[a]
          violations << "(#{a} >> #{b}) => #{chain.inspect} accepts: #{self.class.witnesses(widened)}" if widened.any?
        end
      end

      report(violations)
    end
  end

  # REDUCTION FIDELITY — the strongest laws here, and the ones aimed squarely at
  # the four consumers named at the top of this file.
  #
  # Every operator has an UNREDUCED form: the node that would exist if the
  # Optimizer did nothing (`And`/`Or`/`Conjunction.build`). Reduction exists to
  # make the tree cheaper, never to change what it accepts — so the reduced node
  # and the unreduced one must accept EXACTLY the same values.
  #
  # This catches what SEQUENCE structurally cannot. Deleting the right-hand side of
  # a chain doesn't widen the chain past its LEFT side, so `a >> b` collapsing to
  # `a` slips through an "accepts no more than `a`" check while having silently
  # discarded `b`'s validation. Comparing against `And.new(a, b)` sees it.
  describe 'REDUCTION FIDELITY' do
    # Shared driver: build both forms, compare accepted sets, describe the drift.
    def self.fidelity_violations(op_label, skip_left: nil, skip_pair: nil)
      violations = []
      LABELS.each do |a|
        next if skip_left && skip_left.call(SPECIMENS[a])

        LABELS.each do |b|
          next if a == b
          next if skip_pair && skip_pair.call(SPECIMENS[a], SPECIMENS[b])

          reduced = build { yield(:reduced, SPECIMENS[a], SPECIMENS[b]) }
          next if reduced.nil?

          reference = build { yield(:reference, SPECIMENS[a], SPECIMENS[b]) }
          next if reference.nil?

          got, = probe(reduced)
          want, = probe(reference)
          next if got == want

          detail = []
          detail << "no longer accepts #{witnesses(want - got)}" if (want - got).any?
          detail << "now also accepts #{witnesses(got - want)}" if (got - want).any?
          violations << "#{a} #{op_label} #{b} reduced to #{reduced.inspect}, which #{detail.join(' and ')}"
        end
      end
      violations
    end

    it 'preserves the accepted set when reducing a >> chain' do
      report(self.class.fidelity_violations('>>') do |form, a, b|
        form == :reduced ? a >> b : Plumb::And.new(a, b)
      end)
    end

    it 'preserves the accepted set when reducing a | union' do
      report(self.class.fidelity_violations('|', skip_left: ->(t) { t.is_a?(Plumb::AnyClass) }) do |form, a, b|
        form == :reduced ? a | b : Plumb::Or.new(a, b)
      end)
    end

    # Hash-to-Hash pairs are out of scope here, because for them `&` is not a
    # reduction of the unreduced node at all. HashClass#& implements its own
    # operation — the SHARED key set with each shared field met — while
    # Conjunction.build would produce a sequential And that runs one record after
    # the other, and a record drops the keys it does not declare, so the second
    # sees a hash the first already stripped. The two are different operations, not
    # a node and its reduction, so a mismatch here says nothing.
    #
    # NOTE this leaves Hash meets unpoliced by the property laws. MEET above cannot
    # take over: it is gated on #value_preserving?, which a record is not (it drops
    # undeclared keys), and ungating it would report a deliberate choice as a
    # failure — a Hash meet keeps only the SHARED keys, so it forgets a key either
    # side required and can accept what that side rejects
    # (`Hash[name: String, age: Integer] & Hash[name?: String, age: Integer, ...]`
    # admits `{age: 42}`, which the left rejects). Hash meets are covered instead by
    # the worked examples in spec/intersection_spec.rb and the typed-keys specs.
    it 'preserves the accepted set when reducing an & intersection' do
      hash_pair = ->(a, b) { a.is_a?(Plumb::HashClass) && b.is_a?(Plumb::HashClass) }
      report(self.class.fidelity_violations('&', skip_pair: hash_pair) do |form, a, b|
        form == :reduced ? a & b : Plumb::Conjunction.build(a, b)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Lattice laws, over the grid above
  # ---------------------------------------------------------------------------

  # These are the same laws spec/invariants_spec.rb asserts, re-run over a grid
  # that deliberately includes what that one leaves out: the bare `Types::Hash`
  # top, literal ValueClass types, Not, Deferred, and the Policy/Metadata
  # wrappers. Kept here rather than added there so the two files stay
  # independently readable — that one snapshots a relation, this one stress-tests
  # it.
  describe 'LATTICE' do
    it 'is reflexive' do
      report(LABELS.reject { |l| Plumb::Subtyping.subtype?(SPECIMENS[l], SPECIMENS[l]) }
                   .map { |l| "#{l} is not a subtype of itself" })
    end

    it 'has Any as top' do
      report(LABELS.reject { |l| Plumb::Subtyping.subtype?(SPECIMENS[l], Types::Any) }
                   .map { |l| "#{l} is not a subtype of Any" })
    end

    it 'has Never as bottom' do
      report(LABELS.reject { |l| Plumb::Subtyping.subtype?(Types::Never, SPECIMENS[l]) }
                   .map { |l| "Never is not a subtype of #{l}" })
    end

    it 'is transitive' do
      violations = []
      LABELS.each do |a|
        LABELS.each do |b|
          next unless Plumb::Subtyping.subtype?(SPECIMENS[a], SPECIMENS[b])

          LABELS.each do |c|
            next unless Plumb::Subtyping.subtype?(SPECIMENS[b], SPECIMENS[c])
            next if Plumb::Subtyping.subtype?(SPECIMENS[a], SPECIMENS[c])

            violations << "#{a} <= #{b} <= #{c}, but not #{a} <= #{c}"
          end
        end
      end

      report(violations)
    end

    # No type may sit under two types that share no inhabitant. The pairs are
    # hardcoded and asserted disjoint over the corpus first — an empirically
    # overlapping pair would make this vacuous (`Hash[_:Integer]` and
    # `Hash[_:String]` look disjoint but both accept `{}`).
    it 'never places a type under two disjoint types' do
      disjoint = [%w[String Integer], %w[String Numeric], %w[Integer Nil]]
      disjoint.each do |(x, y)|
        expect(ACCEPTS[x] & ACCEPTS[y]).to be_empty, "#{x} and #{y} overlap; pick a disjoint pair"
      end

      violations = LABELS.reject { |l| SPECIMENS[l].is_a?(Plumb::NeverClass) }.flat_map do |label|
        disjoint.filter_map do |(x, y)|
          both = Plumb::Subtyping.subtype?(SPECIMENS[label], SPECIMENS[x]) &&
                 Plumb::Subtyping.subtype?(SPECIMENS[label], SPECIMENS[y])
          "#{label} is a subtype of both #{x} and #{y}" if both
        end
      end

      report(violations)
    end
  end
end

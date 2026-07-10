# frozen_string_literal: true

require 'set'
require 'spec_helper'

# Rung-1 structural reduction of `left >> right`: when `right` re-asserts a base
# TYPE that `left` already guarantees, that duplicated gate is dropped by
# re-parenting `right`'s refinements onto `left` (see Plumb::Subtyping.reduce_step).
RSpec.describe 'composition reduction (>>)' do
  module RTypes
    include Plumb::Types
  end

  # The matcher chain of a Constraint, leaf-first: [-10..110, 0..100, ::Integer].
  def matcher_chain(type)
    chain = []
    node = type
    while node.is_a?(Plumb::Constraint)
      chain << node.matcher
      node = node.base
    end
    chain
  end

  describe 'range intersection (rung 2)' do
    it '>> intersects to the narrower range (always left, after the strict check)' do
      # >> checks composability first (left <: right), so the surviving range is
      # always left's own: Integer[0..100] ∩ (-10..110) == 0..100.
      reduced = RTypes::Integer[0..100] >> RTypes::Integer[-10..110]
      expect(reduced).to be_a(Plumb::Constraint)
      expect(reduced).to eq(RTypes::Integer[0..100])
      expect(matcher_chain(reduced)).to eq([0..100, ::Integer]) # ::Integer once, single range
    end

    it '>> Integer[0..] collapses to Integer[0..100]' do
      expect(RTypes::Integer[0..100] >> RTypes::Integer[0..]).to eq(RTypes::Integer[0..100])
    end

    it '#[] intersects stacked ranges: Integer[0..100][10..] == Integer[10..100]' do
      merged = RTypes::Integer[0..100][10..]
      expect(merged).to eq(RTypes::Integer[10..100])
      expect(matcher_chain(merged)).to eq([10..100, ::Integer])
    end

    it '#/ intersects: Integer[0..40] / Integer[2..10] == Integer[2..10]' do
      expect(RTypes::Integer[0..40] / RTypes::Integer[2..10]).to eq(RTypes::Integer[2..10])
    end

    it 'carries exclusive ends and generalizes to String ranges' do
      expect(RTypes::Integer[0...10][5..]).to eq(RTypes::Integer[5...10])
      expect(RTypes::String['a'..'m']['c'..'z']).to eq(RTypes::String['c'..'m'])
    end

    it 'reduces a disjoint intersection to Never (as #& does)' do
      empty = RTypes::Integer[0..5][10..]
      expect(empty).to eq(RTypes::Never)
      expect(empty).to eq(RTypes::Integer[0..5] & RTypes::Integer[10..])
      expect(empty.resolve(3).valid?).to be(false)
    end

    it 'validates identically to the pre-reduction composition' do
      reduced = RTypes::Integer[0..100][10..] # == Integer[10..100]
      assert_result(reduced.resolve(50), 50, true)
      expect(reduced.resolve(5).errors).to eq('Must be within 10..100')
      expect(reduced.resolve(200).errors).to eq('Must be within 10..100')
      expect(reduced.resolve('x').errors).to eq('Must be a Integer')
    end
  end

  describe 'set intersection (rung 2)' do
    it '#[] intersects stacked sets: Integer[Set[1,2,3]][Set[2,3,4]] == Integer[Set[2,3]]' do
      merged = RTypes::Integer[Set[1, 2, 3]][Set[2, 3, 4]]
      expect(merged).to eq(RTypes::Integer[Set[2, 3]])
      expect(matcher_chain(merged)).to eq([Set[2, 3], ::Integer])
    end

    it '#/ intersects sets' do
      expect(RTypes::Integer[Set[1, 2, 3]] / RTypes::Integer[Set[2, 3, 4]])
        .to eq(RTypes::Integer[Set[2, 3]])
    end

    it '>> composes and reduces a subset narrowing' do
      expect(RTypes::Integer[Set[2, 3]] >> RTypes::Integer[Set[1, 2, 3, 4]])
        .to eq(RTypes::Integer[Set[2, 3]])
    end

    it '>> still raises a non-subset narrowing (strict check first, like ranges)' do
      expect { RTypes::Integer[Set[1, 2, 3]] >> RTypes::Integer[Set[2, 3, 4]] }
        .to raise_error(Plumb::TypeError)
    end

    it 'reduces an empty set intersection to Never (as #& does)' do
      empty = RTypes::Integer[Set[1, 2]][Set[3, 4]]
      expect(empty).to eq(RTypes::Never)
      expect(empty).to eq(RTypes::Integer[Set[1, 2]] & RTypes::Integer[Set[3, 4]])
      expect(empty.resolve(1).valid?).to be(false)
    end

    it 'validates membership after intersection' do
      t = RTypes::Integer[Set[1, 2, 3]][Set[2, 3, 4]] # == Integer[Set[2,3]]
      assert_result(t.resolve(2), 2, true)
      expect(t.resolve(1).valid?).to be(false)
    end
  end

  describe 'a pure redundant base-type gate' do
    it 'collapses A >> Integer to A' do
      reduced = RTypes::Integer[0..100] >> RTypes::Integer
      expect(reduced).to eq(RTypes::Integer[0..100])
      expect(reduced).to be_a(Plumb::Constraint)
    end

    it 'collapses a widening chain A >> WiderType to A (precise output_type)' do
      expect(RTypes::Integer >> RTypes::Numeric).to eq(RTypes::Integer)
      expect((RTypes::Integer[1..5] >> RTypes::Integer >> RTypes::Numeric))
        .to eq(RTypes::Integer[1..5])
    end
  end

  describe 'a redundant value-preserving refinement is absorbed' do
    it 'drops a vacuous where-clause the left already guarantees' do
      reduced = RTypes::String.where(size: 3..10) >> RTypes::String.where(size: 0..)
      expect(reduced).to eq(RTypes::String.where(size: 3..10))
      expect(reduced.resolve('abcde').valid?).to be(true)
      expect(reduced.resolve('ab').valid?).to be(false)
      expect(reduced.resolve('abcdefghijkl').valid?).to be(false)
    end

    it 'drops a redundant union the left already subsumes' do
      expect(RTypes::Integer[0..100] >> (RTypes::Integer | RTypes::Float))
        .to eq(RTypes::Integer[0..100])
    end

    it 'reduces where-clauses whose attribute values are themselves Plumb types' do
      reduced = RTypes::String.where(size: RTypes::Integer[3..10]) >>
                RTypes::String.where(size: RTypes::Integer[0..])
      expect(reduced).to eq(RTypes::String.where(size: RTypes::Integer[3..10]))
    end

    it 'still raises on a narrowing where-clause (>> forbids narrowing)' do
      expect { RTypes::String.where(size: 3..10) >> RTypes::String.where(size: 5..8) }
        .to raise_error(Plumb::TypeError)
    end
  end

  describe 'attribute constraints (#where) narrow like Constraints' do
    it 'intersects overlapping same-attribute clauses via #/ (one base check)' do
      reduced = RTypes::String.where(size: 0..40) / RTypes::String.where(size: 10..100)
      expect(reduced).to eq(RTypes::String.where(size: 10..40))
    end

    it 'intersects when chaining #where on the same attribute' do
      expect(RTypes::String.where(size: 0..40).where(size: 10..100))
        .to eq(RTypes::String.where(size: 10..40))
    end

    it 'intersects Set-valued clauses' do
      reduced = RTypes::String.where(size: Set[1, 2, 3, 4]) / RTypes::String.where(size: Set[3, 4, 5, 6])
      expect(reduced).to eq(RTypes::String.where(size: Set[3, 4]))
    end

    it 'keeps clauses on different attributes stacked, both applied' do
      reduced = RTypes::String.where(size: 3..10).where(length: 4..8)
      expect(reduced.resolve('xxxx').valid?).to be(true)   # size 4, length 4 — both pass
      expect(reduced.resolve('xx').valid?).to be(false)    # size 2 out of 3..10
      expect(reduced.resolve('x' * 9).valid?).to be(false) # length 9 out of 4..8
    end

    it 'reduces disjoint same-attribute clauses to Never (unsatisfiable, like Constraints)' do
      reduced = RTypes::String.where(size: 0..5) / RTypes::String.where(size: 10..20)
      expect(reduced).to eq(RTypes::Never)
      expect(reduced.resolve('xxx').valid?).to be(false)    # size 3 fails 10..20
      expect(reduced.resolve('x' * 12).valid?).to be(false) # size 12 fails 0..5
    end

    it 'runtime-validates the intersected clause' do
      reduced = RTypes::String.where(size: 0..40) / RTypes::String.where(size: 10..100)
      expect(reduced.resolve('x' * 5).valid?).to be(false)
      expect(reduced.resolve('x' * 25).valid?).to be(true)
      expect(reduced.resolve('x' * 60).valid?).to be(false)
    end
  end

  describe 'bail cases fall back to And' do
    specify 'right is a transform (value-changing barrier)' do
      chain = RTypes::Integer[0..100] >> RTypes::Any.transform(::Integer) { |v| v + 1 }
      expect(chain).to be_a(Plumb::And)
    end

    specify 'right is a union with a value-changing branch (not value-preserving)' do
      coercing = RTypes::Integer | RTypes::String.transform(::Integer, :to_i)
      chain = RTypes::Integer[0..100] >> coercing
      expect(chain).to be_a(Plumb::And)
    end

    specify 'right is rooted in a non-Module matcher (bare range)' do
      # Any[1..100]'s input_type is Any, so there is no duplicated type gate.
      chain = RTypes::Integer[0..100] >> RTypes::Any[1..1000]
      expect(chain).to be_a(Plumb::And)
    end
  end

  describe 'illegal compositions still raise (reduction runs after check)' do
    specify 'left output not a subtype of right' do
      expect { RTypes::Integer[0..100] >> RTypes::Integer[2..50] }
        .to raise_error(Plumb::TypeError)
    end
  end

  describe '#/ (escape-hatch composition) reduces too' do
    it 'drops the redundant base gate on a narrowing #>> would reject' do
      narrowed = RTypes::Integer[0..40] / RTypes::Integer[2..10]
      expect(narrowed).to be_a(Plumb::Constraint)
      expect(narrowed).to eq(RTypes::Integer[0..40][2..10])
      expect(matcher_chain(narrowed).count { |m| m == ::Integer }).to eq(1)
      assert_result(narrowed.resolve(5), 5, true)
      assert_result(narrowed.resolve(30), 30, false)
    end

    it 'preserves the Any-collapse (Any / X == X)' do
      expect(RTypes::Any / RTypes::String).to eq(RTypes::String)
    end

    it 'leaves #value as an And (ValueClass is not a Constraint)' do
      expect(RTypes::String.value('x')).to be_a(Plumb::And)
    end
  end

  describe 'union absorption (Or reduction, refinement-only)' do
    it 'absorbs the narrower branch to the wider (order-independent)' do
      expect(RTypes::Integer | RTypes::Numeric).to eq(RTypes::Numeric)
      expect(RTypes::Numeric | RTypes::Integer).to eq(RTypes::Numeric)
    end

    it 'dedupes X | X' do
      expect(RTypes::String | RTypes::String).to eq(RTypes::String)
    end

    it 'absorbs a refinement into its base: Integer[0..10] | Integer == Integer' do
      expect(RTypes::Integer[0..10] | RTypes::Integer).to eq(RTypes::Integer)
    end

    it 'keeps disjoint branches as an Or' do
      expect(RTypes::String | RTypes::Integer).to be_a(Plumb::Or)
    end

    it 'does NOT reduce a coercion (transform) branch — the union is preserved' do
      coerce = RTypes::String.transform(::Integer, :to_i) # accepts Strings, outputs Integer
      u = coerce | RTypes::Numeric
      expect(u).to be_a(Plumb::Or)
      assert_result(u.resolve('5'), 5, true)   # string branch still coerces
      assert_result(u.resolve(2.5), 2.5, true) # numeric branch still accepted
    end

    it 'does NOT absorb across an identity-carrying wrapper (subtype? sees through it)' do
      # A named node (Email) is subtype-equal to String, but absorbing it would
      # drop its :email identity — and its JSON-schema `format`.
      u = RTypes::Email | RTypes::String
      expect(u).to be_a(Plumb::Or)
      expect(u.to_json_schema(root: false)['anyOf'])
        .to include('type' => 'string', 'format' => 'email')

      # Metadata / default wrappers are likewise not dropped.
      expect((RTypes::String | RTypes::String.metadata(x: 1))).to be_a(Plumb::Or)
    end

    it 'still dedupes equal wrapper nodes (the survivor IS the identity)' do
      expect(RTypes::Email | RTypes::Email).to eq(RTypes::Email)
    end

    it 'validates identically to the un-reduced union' do
      r = RTypes::Integer | RTypes::Numeric # == Numeric
      assert_result(r.resolve(5), 5, true)
      assert_result(r.resolve(5.5), 5.5, true)
      expect(r.resolve('x').valid?).to be(false)
    end
  end

  describe 'union factoring: shared base checked once (distributivity)' do
    it 'factors a shared root type into a :refined_union of And(base, Or(suffixes))' do
      u = RTypes::String[/d/] | RTypes::String[/c/]

      expect(u.node_name).to eq(:refined_union)
      expect(u.type).to be_a(Plumb::And)
      expect(u.type.input_type).to eq(RTypes::String)  # base
      expect(u.type.output_type).to be_a(Plumb::Or)    # disjunction of bare suffixes
    end

    it 'is runtime-equivalent to the un-factored union' do
      u = RTypes::String[/d/] | RTypes::String[/c/]

      assert_result(u.resolve('dog'), 'dog', true)   # matches /d/
      assert_result(u.resolve('cat'), 'cat', true)   # matches /c/ (exercises right branch)
      assert_result(u.resolve('xyz'), 'xyz', false)  # a string, matches neither
      expect(u.resolve(42).valid?).to be(false)      # not a string
    end

    it 'renders JSON Schema as the base type with anyOf of the branch matchers' do
      schema = Plumb::JSONSchemaVisitor.call(RTypes::String[/d/] | RTypes::String[/c/])

      expect(schema['type']).to eq('string')
      expect(schema['anyOf'].map { |b| b['pattern'] }).to contain_exactly('d', 'c')
    end

    it 'factors the longest common prefix, not just the root' do
      u = RTypes::String[/a/][/b/] | RTypes::String[/a/][/c/]

      expect(u.node_name).to eq(:refined_union)
      expect(u.type.input_type).to eq(RTypes::String[/a/])
    end

    it 'keeps disjoint roots as a plain Or' do
      expect(RTypes::String[/d/] | RTypes::Integer[1..3]).to be_a(Plumb::Or)
    end

    it 'lets absorption win when one branch subsumes the other' do
      expect(RTypes::String[/d/] | RTypes::String).to eq(RTypes::String)
    end

    it 'does NOT factor when a branch transforms (coercion preserved)' do
      coerce = RTypes::String.transform(::Integer, :to_i)

      expect(coerce | RTypes::String[/c/]).to be_a(Plumb::Or)
    end

    it 'has a stable ==' do
      expect(RTypes::String[/d/] | RTypes::String[/c/]).to eq(RTypes::String[/d/] | RTypes::String[/c/])
    end

    context 'general composition: (A >> B) | (A >> C) with any suffixes' do
      let(:to_sym) { RTypes::String.transform(::Symbol, :to_sym) }
      let(:to_i)   { RTypes::String.transform(::Integer, :to_i) }

      it 'factors a value-preserving prefix out, leaving transform suffixes in the Or' do
        u = (RTypes::String >> to_sym) | (RTypes::String >> to_i)

        expect(u.node_name).to eq(:refined_union)
        expect(u.type.input_type).to eq(RTypes::String)  # A pulled out (checked once)
        expect(u.type.output_type).to be_a(Plumb::Or)    # (B | C)
      end

      it 'is runtime-equivalent to the un-factored union (suffixes still run)' do
        factored = (RTypes::String >> to_sym) | (RTypes::String >> to_i)
        plain    = Plumb::Or.new(RTypes::String >> to_sym, RTypes::String >> to_i)

        %w[hi 42].each { |v| assert_result(factored.resolve(v), plain.resolve(v).value, true) }
        expect(factored.resolve(99).valid?).to be(false) # not a string
      end

      it 'keeps the base type in JSON Schema (disjunction folded, not dropped)' do
        u = (RTypes::String >> to_sym) | (RTypes::String >> to_i)

        expect(Plumb::JSONSchemaVisitor.call(u)['type']).to eq('string')
      end

      it 'does NOT factor a transform prefix (purity is unprovable)' do
        coerce = RTypes::String.transform(::Integer, :to_i)
        left   = Plumb::And.new(coerce, RTypes::Integer[1..])
        right  = Plumb::And.new(coerce, RTypes::Integer[0..0])

        expect(Plumb::Subtyping.factor_union(left, right)).to be_nil
      end
    end

    context 'n-ary folding: 3+ branches over one prefix, checked once' do
      it 'folds a 3-way union into a single refined_union (not a nested Or)' do
        u = RTypes::String[/a/] | RTypes::String[/b/] | RTypes::String[/c/]

        expect(u.node_name).to eq(:refined_union) # NOT :or — base is shared, not re-checked
        expect(u.type.input_type).to eq(RTypes::String)
      end

      it 'keeps every branch reachable at runtime after folding' do
        u = RTypes::String[/a/] | RTypes::String[/b/] | RTypes::String[/c/]

        assert_result(u.resolve('a!'), 'a!', true)
        assert_result(u.resolve('b!'), 'b!', true)
        assert_result(u.resolve('c!'), 'c!', true) # third branch, previously behind a re-checked base
        assert_result(u.resolve('zzz'), 'zzz', false)
        expect(u.resolve(9).valid?).to be(false)
      end

      it 'folds a 4-way union too' do
        u = RTypes::String[/a/] | RTypes::String[/b/] | RTypes::String[/c/] | RTypes::String[/d/]

        expect(u.node_name).to eq(:refined_union)
        expect(u.type.input_type).to eq(RTypes::String)
      end

      it 'folds a shared multi-step prefix once (String[/x/])' do
        u = RTypes::String[/x/][/a/] | RTypes::String[/x/][/b/] | RTypes::String[/x/][/c/]

        expect(u.node_name).to eq(:refined_union)
        expect(u.type.input_type).to eq(RTypes::String[/x/])
      end

      it 'folds a 3-way composition with transform suffixes' do
        b = RTypes::String.transform(::Symbol, :to_sym)
        c = RTypes::String.transform(::Integer, :to_i)
        d = RTypes::String.transform(::Float, :to_f)
        u = (RTypes::String >> b) | (RTypes::String >> c) | (RTypes::String >> d)

        expect(u.node_name).to eq(:refined_union)
        expect(u.type.input_type).to eq(RTypes::String)
      end

      it 'renders a FLAT anyOf in JSON Schema (no nested Or)' do
        schema = Plumb::JSONSchemaVisitor.call(RTypes::String[/a/] | RTypes::String[/b/] | RTypes::String[/c/])

        expect(schema['anyOf'].map { |b| b['pattern'] }).to contain_exactly('a', 'b', 'c')
        expect(schema['anyOf'].any? { |b| b.key?('anyOf') }).to be(false) # flattened
      end

      it 'does NOT flatten a branch carrying other keys (soundness)' do
        # (String[/a/] | String[/b/]) renders {type:string, anyOf:[…]}; OR'd with an
        # Integer it must stay nested, else the string patterns escape the type gate.
        schema = Plumb::JSONSchemaVisitor.call((RTypes::String[/a/] | RTypes::String[/b/]) | RTypes::Integer[1..3])
        string_branch = schema['anyOf'].find { |b| b['type'] == 'string' }

        expect(string_branch).to have_key('anyOf')
      end
    end
  end
end

# A covariant container is value-preserving exactly when its element/child types
# are, so `#>>` / `#|` reduce it like the scalar case (see ArrayClass/TupleClass/
# HashMap#value_preserving?).
RSpec.describe 'covariant container reductions' do
  module CTypes
    include Plumb::Types
  end

  it '>> drops a redundant wider Array, like the scalar case' do
    expect(CTypes::Array[CTypes::Integer] >> CTypes::Array[CTypes::Numeric])
      .to eq(CTypes::Array[CTypes::Integer])
    expect(CTypes::Array[CTypes::Integer] >> CTypes::Array[CTypes::Integer])
      .to eq(CTypes::Array[CTypes::Integer])
  end

  it '| absorbs the narrower Array into the wider' do
    expect(CTypes::Array[CTypes::Integer] | CTypes::Array[CTypes::Numeric])
      .to eq(CTypes::Array[CTypes::Numeric])
  end

  it 'reduces Tuples and HashMaps the same way' do
    expect(CTypes::Tuple[CTypes::Integer, CTypes::String] >> CTypes::Tuple[CTypes::Numeric, CTypes::String])
      .to eq(CTypes::Tuple[CTypes::Integer, CTypes::String])
    expect(CTypes::Hash[CTypes::Symbol, CTypes::Integer] >> CTypes::Hash[CTypes::Symbol, CTypes::Numeric])
      .to eq(CTypes::Hash[CTypes::Symbol, CTypes::Integer])
  end

  it 'does NOT reduce when an element type coerces (not value-preserving)' do
    coercing = CTypes::Array[CTypes::Integer.transform(::Float, &:to_f)]
    expect(Plumb::Subtyping.value_preserving?(coercing)).to be(false)
    # a coercing branch survives the union rather than being absorbed
    union = CTypes::Array[CTypes::Integer] | coercing
    expect(union).to be_a(Plumb::Or)
  end

  it 'keeps a filtered map non-value-preserving (it drops entries)' do
    expect(Plumb::Subtyping.value_preserving?(CTypes::Hash[CTypes::Symbol, CTypes::Integer].filtered)).to be(false)
  end
end

# A record `left >> right` reduces to `left` when `right` merely re-validates
# left's output without dropping or converting anything (see
# Subtyping.redundant_record_refinement?).
RSpec.describe 'record (Hash) composition reductions' do
  module HRTypes
    include Plumb::Types
  end

  it 'drops a redundant wider record, like the scalar case' do
    expect(HRTypes::Hash[age: HRTypes::Integer] >> HRTypes::Hash[age: HRTypes::Numeric])
      .to eq(HRTypes::Hash[age: HRTypes::Integer])
  end

  it 'reduces across several keys' do
    expect(HRTypes::Hash[a: HRTypes::Integer, b: HRTypes::Integer] >>
           HRTypes::Hash[a: HRTypes::Numeric, b: HRTypes::Numeric])
      .to eq(HRTypes::Hash[a: HRTypes::Integer, b: HRTypes::Integer])
  end

  it 'reduces when both carry a matching value-preserving catch-all' do
    expect(HRTypes::Hash[a: HRTypes::Integer, _: HRTypes::Any] >>
           HRTypes::Hash[a: HRTypes::Numeric, _: HRTypes::Any])
      .to eq(HRTypes::Hash[a: HRTypes::Integer, _: HRTypes::Any])
  end

  it 'reduces identically at runtime' do
    reduced = HRTypes::Hash[age: HRTypes::Integer] >> HRTypes::Hash[age: HRTypes::Numeric]
    assert_result(reduced.resolve(age: 5, extra: 9), { age: 5 }, true)
  end

  it 'does NOT reduce when the right record drops a key the left keeps' do
    type = HRTypes::Hash[age: HRTypes::Integer, name: HRTypes::String] >> HRTypes::Hash[age: HRTypes::Numeric]
    expect(type).to be_a(Plumb::And)
    # right drops :name, so the composed result differs from the left alone
    assert_result(type.resolve(age: 5, name: 'x'), { age: 5 }, true)
  end

  it 'does NOT reduce when the right record would drop the left catch-all tail' do
    expect(HRTypes::Hash[a: HRTypes::Integer, _: HRTypes::Any] >> HRTypes::Hash[a: HRTypes::Numeric])
      .to be_a(Plumb::And)
  end

  it 'does NOT reduce when a right field converts the value (front/back coercion)' do
    money = Class.new
    back = HRTypes::Hash[price: HRTypes::Integer.build(money), _: HRTypes::Any]
    expect(HRTypes::Hash[price: HRTypes::Integer] >> back).to be_a(Plumb::And)
  end
end

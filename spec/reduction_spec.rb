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

    it 'leaves an empty intersection stacked (still rejects every value)' do
      empty = RTypes::Integer[0..5][10..]
      expect(matcher_chain(empty)).to eq([10.., 0..5, ::Integer]) # not merged
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

    it 'merges an empty intersection to Set[] (matches nothing)' do
      empty = RTypes::Integer[Set[1, 2]][Set[3, 4]]
      expect(empty).to eq(RTypes::Integer[Set[]])
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

  describe 'bail cases fall back to And' do
    specify 'right is a transform (value-changing barrier)' do
      chain = RTypes::Integer[0..100] >> RTypes::Any.transform(::Integer) { |v| v + 1 }
      expect(chain).to be_a(Plumb::And)
    end

    specify 'right is a union' do
      chain = RTypes::Integer[0..100] >> (RTypes::Integer | RTypes::Float)
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

    it 'validates identically to the un-reduced union' do
      r = RTypes::Integer | RTypes::Numeric # == Numeric
      assert_result(r.resolve(5), 5, true)
      assert_result(r.resolve(5.5), 5.5, true)
      expect(r.resolve('x').valid?).to be(false)
    end
  end
end

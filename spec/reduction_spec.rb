# frozen_string_literal: true

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

  describe 'two refinements sharing a base type' do
    subject(:reduced) { RTypes::Integer[0..100] >> RTypes::Integer[-10..110] }

    it 'builds a re-parented Constraint chain, not an And' do
      expect(reduced).to be_a(Plumb::Constraint)
      expect(reduced).to eq(RTypes::Integer[0..100][-10..110])
      expect(reduced.inspect).to end_with('[0..100][-10..110]')
    end

    it 'checks the base type (::Integer) exactly once' do
      chain = matcher_chain(reduced)
      expect(chain.count { |m| m == ::Integer }).to eq(1)
      expect(chain).to include(0..100, -10..110) # both ranges preserved (rung 1)
    end

    it 'keeps the redundant range (rung 1, not value-subsumption rung 2)' do
      # Semantically equal to Integer[0..100], but structurally still carries the
      # wider -10..110 refinement — we did not compare range values.
      expect(reduced).not_to eq(RTypes::Integer[0..100])
      expect(matcher_chain(reduced)).to eq([-10..110, 0..100, ::Integer])
    end

    it 'validates identically to the pre-reduction composition' do
      assert_result(reduced.resolve(50), 50, true)
      bad_range = reduced.resolve(200)
      expect(bad_range.valid?).to be(false)
      expect(bad_range.errors).to eq('Must be within 0..100')
      bad_type = reduced.resolve('x')
      expect(bad_type.valid?).to be(false)
      expect(bad_type.errors).to eq('Must be a Integer')
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
end

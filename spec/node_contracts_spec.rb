# frozen_string_literal: true

require 'spec_helper'

# The invariants of the four two-sided node classes, as CONTRACTS rather than as a
# recorded snapshot.
#
# `#value_preserving?` is load-bearing well beyond its own value: Conjunction.build
# and Disjunction.build choose a node class by it, Optimizer gates absorption and
# factoring on it, Subtyping.intersect gates its subsumption drops on it, and
# Codec::Rewriter reads it to decide what a node honestly describes. Breaking it
# changes behaviour all over, and until this file existed the ONLY thing that
# noticed was the regenerable AST-shape fixture in spec/invariants_spec.rb — a
# snapshot, which can always be made green by regenerating it.
#
# The sibling contracts (Intersection#output_type, Union#output_type/#input_type,
# And#subtype_identity) are already pinned by named specs in reduction_spec.rb,
# type_cache_spec.rb and type_subtyping_spec.rb, so they are not repeated here.
RSpec.describe 'two-sided node contracts' do
  module NTypes
    include Plumb::Types
  end

  let(:refinement) { NTypes::String.where(size: 1..3) }        # Intersection
  let(:composition) { NTypes::String >> NTypes::String.transform(::Integer, &:to_i) } # And
  let(:union) { NTypes::String | NTypes::Integer }             # Union
  let(:choice) { NTypes::Integer | NTypes::String.transform(::Integer, &:to_i) } # Or

  it 'builds the node class the operands imply' do
    expect(refinement).to be_a(Plumb::Intersection)
    expect(composition).to be_a(Plumb::And)
    expect(union).to be_a(Plumb::Union)
    expect(choice).to be_a(Plumb::Or)
  end

  describe '#value_preserving?' do
    # An INVARIANT of the node, not a computation over its children:
    # Conjunction.build only produces an Intersection when neither side alters the
    # value. This is what lets callers test `is_a?(Intersection)` where they would
    # otherwise have to test `is_a?(And) && value_preserving?(node)` —
    # Optimizer.reduce_step does exactly that.
    it 'is true for a meet' do
      expect(Plumb::Subtyping.value_preserving?(refinement)).to be(true)
      expect(refinement.value_preserving?).to be(true)
    end

    # A composition always has a converting side — that is why it is an And and not
    # an Intersection — so it never preserves the value.
    it 'is false for a composition' do
      expect(Plumb::Subtyping.value_preserving?(composition)).to be(false)
    end

    it 'is true for a join' do
      expect(Plumb::Subtyping.value_preserving?(union)).to be(true)
      expect(union.value_preserving?).to be(true)
    end

    # Or keeps it computed rather than hardcoded false: Disjunction.build only
    # routes the converting case there, but Or.new stays reachable directly.
    it 'is computed from the branches for a choice' do
      expect(Plumb::Subtyping.value_preserving?(choice)).to be(false)
      expect(Plumb::Or.new(NTypes::String, NTypes::Integer).value_preserving?).to be(true)
    end
  end

  # The consequences, so the above are not merely getter tests: the predicate is
  # what selects the node class, and Optimizer.reduce_step relies on a nested
  # refinement still BEING an Intersection.
  describe 'the predicate drives node selection' do
    it 'keeps a chain of refinements a meet' do
      chained = NTypes::String.where(size: 1..10).where(bytesize: 1..10)
      expect(chained).to be_a(Plumb::Intersection)
      expect(Plumb::Subtyping.value_preserving?(chained)).to be(true)
    end

    it 'turns a conjunction into a composition as soon as one side converts' do
      expect(NTypes::String.where(size: 1..3) >> NTypes::String.transform(:to_sym))
        .to be_a(Plumb::And)
    end

    it 'narrows a refinement through a meet but not through a composition' do
      # reduce_step recurses into an Intersection's conjuncts (it is safe to
      # reorder a meet) and treats a composition as a barrier.
      expect(NTypes::Integer[0..100] >> NTypes::Integer[-10..110])
        .to eq(NTypes::Integer[0..100][-10..110])
    end
  end
end

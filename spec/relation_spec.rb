# frozen_string_literal: true

require 'set'
require 'spec_helper'

RSpec.describe 'semantic matcher relations' do
  module RelationTypes
    include Plumb::Types
  end

  it 'keeps the public Constraint matcher raw while applying range semantics' do
    matcher = 1..3
    constraint = Plumb::Constraint.new(matcher)

    expect(constraint.matcher).to equal(matcher)
    expect(constraint.children.first).to equal(matcher)
    expect(constraint <= Plumb::Constraint.new(0..4)).to be(true)
    expect(constraint <= Plumb::Constraint.new(2..4)).to be(false)
  end

  it 'compares supported matcher kinds through the public type relation' do
    expect(RelationTypes::Any[::Integer] <= RelationTypes::Any[::Numeric]).to be(true)
    expect(RelationTypes::Any[1] <= RelationTypes::Any[1..3]).to be(true)
    expect(RelationTypes::Any['ax'] <= RelationTypes::Any[/a/]).to be(true)
    expect(RelationTypes::Any[Set[1, 2]] <= RelationTypes::Any[Set[1, 2, 3]]).to be(true)
    expect(RelationTypes::Any[2..5] <= RelationTypes::Any[1..10]).to be(true)
  end

  it 'rejects disproven matcher relationships' do
    expect(RelationTypes::Any[::Numeric] <= RelationTypes::Any[::Integer]).to be(false)
    expect(RelationTypes::Any[Set[1, 4]] <= RelationTypes::Any[Set[1, 2, 3]]).to be(false)
    expect(RelationTypes::Any[0..5] <= RelationTypes::Any[1..10]).to be(false)
  end

  it 'merges compatible matcher intersections' do
    range = RelationTypes::Any[1..5][3..8]
    set = RelationTypes::Any[Set[1, 2]][Set[2, 3]]
    patterns = RelationTypes::Any[/a/][/b/]

    expect(range).to be_a(Plumb::Constraint)
    expect(range.matcher).to eq(3..5)
    expect(set).to be_a(Plumb::Constraint)
    expect(set.matcher).to eq(Set[2])
    expect(patterns.resolve('ab')).to be_valid
    expect(patterns.resolve('a')).not_to be_valid
  end

  it 'uses known matcher domains to reject incompatible refinements' do
    expect { RelationTypes::Integer[/x/] }.to raise_error(Plumb::TypeError)
    expect { RelationTypes::String[1..3] }.to raise_error(Plumb::TypeError)
    expect { RelationTypes::Integer[Set[1, 'x']] }.not_to raise_error
    expect { RelationTypes::Integer[proc { true }] }.not_to raise_error
  end

  it 'does not claim incomparable Range relationships as subtypes' do
    expect(RelationTypes::Any[1..3] <= RelationTypes::Any[..'z']).to be(false)
  end

  it 'does not claim unsupported matcher collaborations as subtypes' do
    expect(RelationTypes::Any[Set['a']] <= RelationTypes::Any[/a/]).to be(false)
    expect(RelationTypes::Any[proc { true }] <= RelationTypes::Any[::Proc]).to be(false)
  end

  it 'keeps unsupported matcher pairs as runtime intersections' do
    intersection = Plumb::Constraint.new(Set['a']) & Plumb::Constraint.new(/a/)

    expect(intersection).to be_a(Plumb::Intersection)
    expect(intersection.resolve('a')).to be_valid
    expect(intersection.resolve('b')).not_to be_valid
  end

  it 'does not call unrelated mixin Modules disjoint' do
    left = Module.new
    right = Module.new
    both = Class.new do
      include left
      include right
    end

    intersection = Plumb::Constraint.new(left) & Plumb::Constraint.new(right)

    expect(intersection).to be_a(Plumb::Intersection)
    expect(intersection.resolve(both.new)).to be_valid
  end

  it 'does not treat an opaque comparison as a disjointness proof' do
    positive = RelationTypes::Integer.check('positive') { |value| value.positive? }
    even = RelationTypes::Integer.check('even') { |value| value.even? }

    intersection = positive & even

    expect(intersection).to be_a(Plumb::Intersection)
    expect(intersection.resolve(2)).to be_valid
    expect(intersection.resolve(1)).not_to be_valid
    expect(intersection.resolve(-2)).not_to be_valid
  end

  it 'keeps opaque matchers as runtime refinements of a known base' do
    matcher = Object.new
    def matcher.===(value) = value == 2

    type = RelationTypes::Integer[matcher]

    expect(type.resolve(2)).to be_valid
    expect(type.resolve(3)).not_to be_valid
  end
end

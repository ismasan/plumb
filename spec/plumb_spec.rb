# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb do
  it 'has a version number' do
    expect(Plumb::VERSION).not_to be nil
  end

  # The morphism-flavoured names for #input_type / #output_type. They must
  # DELEGATE, not alias: several types define their own #input_type/#output_type,
  # and an `alias` in Composable would bind Composable's definition instead of
  # dispatching to theirs. This is the regression that would catch that.
  describe '#source_type / #target_type' do
    class Multiplier2
      include Plumb::Implementation[Types::Integer => Types::Integer]
      private def _call(result) = result.valid(result.value * 2)
    end

    class Downcaser2
      extend Plumb::Implementation[Types::String => Types::String]
      def self._call(result) = result.valid(result.value.downcase)
    end

    class StringIntEncoder < Plumb::Encoder[Types::String => Types::Integer]
      def encode(value) = value.to_s
      def decode(value) = value.to_i
    end

    # Every node kind that overrides #input_type or #output_type itself.
    {
      'a Constraint' => Types::String,
      'a converting chain' => Types::String >> Types::String.transform(::Integer, &:to_i),
      'an Or' => Types::String | Types::Integer,
      'a HashMap' => Types::Hash[Types::Symbol, Types::Integer],
      'a Policy' => Types::String.present,
      'Metadata' => Types::String.metadata(label: 'x'),
      'a Node' => Types::Boolean,
      'a Pipeline' => Types::Integer.pipeline { |pl| pl.step(Types::Integer[0..10]) },
      'a Function' => Types::String.transform(::Integer, &:to_i),
      'an AttributeValueMatch' => Types::String.where(size: 1..3),
      'a Static' => Types::Integer.static(10),
      'a Stream' => Types::Stream[Types::Integer],
      'an Implementation instance' => Multiplier2.new,
      'an Implementation class' => Downcaser2
    }.each do |label, type|
      it "delegates for #{label}" do
        expect(type.source_type).to eq(type.input_type)
        expect(type.target_type).to eq(type.output_type)
      end
    end

    it 'mirrors the pair on an Encoder class' do
      expect(StringIntEncoder.source_type).to eq(StringIntEncoder.input_type)
      expect(StringIntEncoder.target_type).to eq(StringIntEncoder.output_type)
    end

    it 'aliases Function as Transform' do
      expect(Plumb::Transform).to be(Plumb::Function)
      expect(Plumb::GuaranteedTransform).to be(Plumb::GuaranteedFunction)
    end
  end

  describe '.decorate' do
    it 'finds and replaces a step' do
      name = Types::String.where(size: 1..10)
      type = Types::Array[name].default([].freeze)
      type2 = Plumb.decorate(type) do |node|
        if node.is_a?(Plumb::ArrayClass)
          sub = node.children.first.transform(String) { |v| "Hello #{v}" }
          Types::Array[sub]
        else
          node
        end
      end

      expect(type.parse).to eq([])
      expect(type2.parse).to eq([])
      assert_result(type.resolve(%w[a b]), %w[a b], true)
      assert_result(type2.resolve(%w[a b]), ['Hello a', 'Hello b'], true)
    end

    it 'finds and replaces a callable wrapped in an opaque Function' do
      type = (Types::Integer >> ->(r) { r.valid(r.value * 2) }).default(1)
      type2 = Plumb.decorate(type) do |node|
        # #opaque? is what singles out a wrapped callable — a bare #is_a?(Function)
        # would also match every #transform / #build / coercion in the tree.
        if node.is_a?(Plumb::Function) && node.opaque?
          Plumb::Composable.wrap(->(r) { r.valid(r.value * 3) })
        else
          node
        end
      end
      expect(type.parse).to eq(1)
      expect(type.parse(2)).to eq(4)
      expect(type2.parse).to eq(1)
      expect(type2.parse(2)).to eq(6)
    end
  end
end

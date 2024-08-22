# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb do
  it 'has a version number' do
    expect(Plumb::VERSION).not_to be nil
  end

  describe '.decorate' do
    it 'finds and replaces a step' do
      name = Types::String.policy(size: 1..10)
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

    it 'finds and replaces a callable wrapped in a Step' do
      type = (Types::Integer >> ->(r) { r.valid(r.value * 2) }).default(1)
      type2 = Plumb.decorate(type) do |node|
        if node.is_a?(Plumb::Step)
          Plumb::Step.new(->(r) { r.valid(r.value * 3) })
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

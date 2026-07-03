# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb::TypeCache do
  specify 'Or of leaf types returns itself as its own io types (no allocation)' do
    union = Types::String | Types::Integer

    expect(union.input_type).to be(union)
    expect(union.output_type).to be(union)
  end

  specify 'Subtyping.resolved_output and .resolved_input return the identical object across calls' do
    chain = Types::String >> Types::String.transform(::Integer, &:size) >> Types::Integer

    expect(Plumb::Subtyping.resolved_output(chain)).to be(Plumb::Subtyping.resolved_output(chain))
    expect(Plumb::Subtyping.resolved_input(chain)).to be(Plumb::Subtyping.resolved_input(chain))
  end

  specify 'resolved io types of unions are cached, including transforming unions' do
    union = Types::String.transform(::Integer, &:size) | Types::Integer

    expect(Plumb::Subtyping.resolved_input(union)).to be(Plumb::Subtyping.resolved_input(union))
    expect(Plumb::Subtyping.resolved_output(union)).to be(Plumb::Subtyping.resolved_output(union))
  end

  specify 'Subtyping.accepted_type returns the identical object across calls' do
    hash = Types::Hash[price: Types::Integer.build(::String, &:to_s)]

    expect(Plumb::Subtyping.accepted_type(hash)).to be(Plumb::Subtyping.accepted_type(hash))
  end

  specify 'StreamClass#input_type returns the identical object across calls and instances' do
    stream_a = Types::Stream[Types::Integer]
    stream_b = Types::Stream[Types::String]

    expect(stream_a.input_type).to be(stream_a.input_type)
    expect(stream_a.input_type).to be(stream_b.input_type)
  end

  specify 'an unfrozen (mutable) Pipeline is never cached and reflects added steps' do
    pipeline = Plumb::Pipeline.new(freeze_after: false)
    expect(Plumb::Subtyping.resolved_output(pipeline)).to be_a(Plumb::AnyClass)

    pipeline.step Types::Integer
    expect(Plumb::Subtyping.resolved_output(pipeline)).to eq(Types::Integer)

    pipeline.step Types::Integer.transform(::String, &:to_s)
    expect(Plumb::Subtyping.resolved_output(pipeline)).to eq(Types::String)
  end

  specify '.fetch only caches frozen keys' do
    unfrozen = Object.new
    calls = 0
    2.times { described_class.fetch(:accepted_type, unfrozen) { calls += 1 } }
    expect(calls).to eq(2)

    frozen = Object.new.freeze
    calls = 0
    2.times { described_class.fetch(:accepted_type, frozen) { calls += 1 } }
    expect(calls).to eq(1)
  end

  specify '.fetch caches falsy results (false / nil), not just truthy ones' do
    [false, nil].each do |falsy|
      frozen = Object.new.freeze
      calls = 0
      values = Array.new(3) { described_class.fetch(:value_preserving, frozen) { calls += 1; falsy } }

      expect(calls).to eq(1), "expected #{falsy.inspect} to be cached after the first compute"
      expect(values).to all(be(falsy))
    end
  end

  specify 'Subtyping.value_preserving? memoizes a transforming (false) union' do
    union = Types::String.transform(::Integer, &:size) | Types::Integer # false: has a transform branch

    expect(Plumb::Subtyping.value_preserving?(union)).to be(false)

    # The frozen node is genuinely cached — the falsy result is stored, not
    # dropped by a truthiness check and recomputed on every call.
    map = Plumb::TypeCache::MAPS.fetch(:value_preserving)
    expect(map.key?(union)).to be(true)
    expect(map[union]).to be(false)
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Function fusion' do
  subject(:fused) { append >> prepend }

  let(:append) { Plumb::Function[String => String] { |r| r.valid(r.value + 'aa') } }
  let(:prepend) { Plumb::Function[String => String] { |r| r.valid('bbbb' + r.value) } }
  let(:int_from_string) { Types::String.transform(::Integer, :to_i) }

  it 'fuses two Functions with a provable boundary into a single Function' do
    expect(fused).to be_instance_of(Plumb::Function)
    expect(fused.input_type).to eq(Types::String)
    expect(fused.output_type).to eq(Types::String)
    assert_result(fused.resolve('x'), 'bbbbxaa', true)
  end

  it 'still validates the fused ends' do
    assert_result(fused.resolve(10), 10, false)

    lying = Plumb::Function[String => String] { |r| r.valid(r.value) } \
      >> Plumb::Function[String => Integer] { |r| r.valid(r.value) }

    expect(lying).to be_instance_of(Plumb::Function)
    assert_result(lying.resolve('x'), 'x', false)
  end

  it 'fuses left-to-right across longer chains' do
    third = Plumb::Function[String => String] { |r| r.valid(r.value + 'cc') }
    chain = append >> prepend >> third

    expect(chain).to be_instance_of(Plumb::Function)
    assert_result(chain.resolve('x'), 'bbbbxaacc', true)
  end

  it 'fuses untyped functions' do
    f1 = Plumb::Function[->(r) { r.valid(r.value * 2) }]
    f2 = Plumb::Function[->(r) { r.valid(r.value + 1) }]
    chain = f1 >> f2

    expect(chain).to be_instance_of(Plumb::Function)
    assert_result(chain.resolve(3), 7, true)
  end

  it 'short-circuits the fn chain when an fn invalidates' do
    seen = []
    failing = Plumb::Function[String => String] { |r| r.invalid(errors: 'nope') }
    tracking = Plumb::Function[String => String] do |r|
      seen << r.value
      r.valid(r.value)
    end
    chain = failing >> tracking

    expect(chain).to be_instance_of(Plumb::Function)
    expect(chain.resolve('x').valid?).to be(false)
    expect(seen).to be_empty
  end

  it 'fuses through the #/ escape hatch too' do
    chain = append / prepend

    expect(chain).to be_instance_of(Plumb::Function)
    assert_result(chain.resolve('x'), 'bbbbxaa', true)
  end

  it 'keeps Guaranteed-ness from the right side' do
    expect(int_from_string).to be_instance_of(Plumb::GuaranteedFunction)

    chain = append >> int_from_string
    expect(chain).to be_instance_of(Plumb::GuaranteedFunction)
    assert_result(chain.resolve('1'), 1, true)

    back_to_plain = int_from_string >> Plumb::Function[Integer => String] { |r| r.valid(r.value.to_s) }
    expect(back_to_plain).to be_instance_of(Plumb::Function)
    assert_result(back_to_plain.resolve('5'), '5', true)
  end

  it 'survives decoration' do
    decorated = Plumb::Decorator.(fused) { |type| type }

    expect(decorated).to be_instance_of(Plumb::Function)
    assert_result(decorated.resolve('x'), 'bbbbxaa', true)
  end

  describe 'compositions that must NOT fuse' do
    it 'keeps an And when the right input type converts the value' do
      right = Plumb::Function[int_from_string => Integer] { |r| r.valid(r.value + 1) }
      composed = append >> right

      expect(composed).to be_a(Plumb::And)
      # 'x' -> 'xaa' -> coerced by the right's input ('xaa'.to_i => 0) -> 1.
      # A fused chain would have fed the String straight to the fn and raised.
      assert_result(composed.resolve('x'), 1, true)
    end

    it 'keeps an And when the left output type converts the value' do
      left = Plumb::Function[Types::String => int_from_string] { |r| r.valid(r.value) }
      right = Plumb::Function[Integer => Integer] { |r| r.valid(r.value + 1) }
      composed = left >> right

      expect(composed).to be_a(Plumb::And)
      assert_result(composed.resolve('5'), 6, true)
    end

    it 'keeps an And when composition is only valid via accepted-type relaxation' do
      left = Plumb::Function[Types::Any => Types::Hash[flags: Types::String]] do |r|
        r.valid(flags: r.value.to_s)
      end
      right = Plumb::Function[Types::Hash[flags: int_from_string] => Types::Hash[flags: Types::Integer]] do |r|
        r.valid(r.value)
      end
      composed = left >> right

      expect(composed).to be_a(Plumb::And)
      # The right's input check does real per-field work: {flags: '5'} -> {flags: 5}.
      assert_result(composed.resolve(5), { flags: 5 }, true)
    end

    it 'keeps an And around subclasses with custom #call semantics' do
      custom_call = Class.new(Plumb::Function) do
        def call(result) = fn.call(result)
      end.new(Types::String, Types::String, ->(r) { r.valid(r.value.upcase) })

      expect(append >> custom_call).to be_a(Plumb::And)
      expect(custom_call >> prepend).to be_a(Plumb::And)
      assert_result((append >> custom_call).resolve('x'), 'XAA', true)
    end
  end
end

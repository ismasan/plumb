# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb::Disjunction::ClassDispatch do
  include Plumb

  # The plain sequential #call, bypassing dispatch.
  def sequential(union, value)
    Plumb::Disjunction.instance_method(:call).bind_call(union, Plumb::Result.new(value))
  end

  def dispatched?(union) = union.singleton_class.include?(Plumb::Disjunction::Dispatched)

  json_value = Types::String | Types::Numeric | Types::Boolean | Types::Nil |
               Types::Array[Types::Any.defer { json_value }] |
               Types::Hash[Types::Symbol, Types::Any.defer { json_value }]

  it 'dispatches unions of three or more branches only' do
    expect(dispatched?(Types::String | Types::Integer | Types::Nil)).to be(true)
    expect(dispatched?(Types::String | Types::Nil)).to be(false)
  end

  it 'resolves and reports errors exactly as the sequential pass does' do
    values = ['x', 1, 1.5, true, false, nil, [1, 'a'], { a: 1 }, { a: { b: [nil] } },
              :sym, Time.now, { 'a' => 1 }, [Object.new]]
    values.each do |value|
      expected = sequential(json_value, value)
      actual = json_value.resolve(value)
      expect([actual.valid?, actual.value, actual.errors]).to eq([expected.valid?, expected.value, expected.errors]),
                                                               "for #{value.inspect}"
    end
  end

  it 'keeps branch order where branches overlap' do
    union = Types::Integer.transform(::Integer) { |n| n * 10 } | Types::Integer | Types::Nil
    expect(union.parse(2)).to eq(20)
  end

  it 'always tries a converting branch, whatever its input' do
    union = Types::Integer | Types::String.transform(::Integer, &:to_i) | Types::Nil
    expect(union.parse('5')).to eq(5)
  end

  it 'ignores module domains, which #extend can add without #class showing it' do
    tag = Module.new
    union = Types::Any[tag] | Types::String | Types::Nil
    tagged = Object.new.extend(tag)
    expect(union.parse(tagged)).to be(tagged)
  end

  it 'keeps dispatching in a copy' do
    expect(dispatched?((Types::String | Types::Integer | Types::Nil).dup)).to be(true)
  end

  it 'dispatches a codec-rewritten union' do
    decoder = Plumb::Codec::JSON >> Types::Hash[Types::Symbol, json_value]
    expect(decoder.parse({ 'a' => { 'b' => [1, nil] } })).to eq({ a: { b: [1, nil] } })

    forms = Plumb::Codec::Forms >> (Types::Integer | Types::Boolean | Types::Nil)
    expect([forms.parse('1'), forms.parse('true'), forms.parse('')]).to eq([1, true, nil])
  end
end

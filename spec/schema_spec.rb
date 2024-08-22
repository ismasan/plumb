# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb::Schema do
  describe 'a schema with nested schemas' do
    subject(:schema) do
      described_class.new do |sc|
        sc.field(:title, Types::String).default('Mr')
        sc.field(:name, Types::String)
        sc.field?(:age, Types::Lax::Integer)
        sc.field(:friend) do |s|
          s.field(:name, Types::String)
        end
        sc.field(:tags, Types::Array[Types::Lax::String]).default([].freeze)
        sc.field(:friends, Types::Array) do |f|
          f.field(:name, Types::String).default('Anonymous')
          f.field(:age, Types::Lax::Integer)
        end.default([].freeze)
      end
    end

    specify 'resolves a valid data structure filling in defaults' do
      data = {
        name: 'Ismael',
        age: '42',
        friend: {
          name: 'Joe'
        }
      }
      result = schema.resolve(data)
      expect(result.valid?).to be true
      expect(result.value).to eq({
                                   title: 'Mr',
                                   name: 'Ismael',
                                   age: 42,
                                   friend: {
                                     name: 'Joe'
                                   },
                                   tags: [],
                                   friends: []
                                 })
    end

    specify '#to_json_schema' do
      schema = described_class.new do |sc|
        sc.field :title, Types::String.default('Mr')
        sc.field? :age, Types::Integer
        sc.field? :foo, Types::String.transform(::Integer, &:to_i)
      end
      data = schema.to_json_schema
      expect(data).to eq({
                           '$schema' => 'https://json-schema.org/draft-08/schema#',
                           'type' => 'object',
                           'properties' => {
                             'title' => { 'type' => 'string', 'default' => 'Mr' },
                             'age' => { 'type' => 'integer' },
                             'foo' => { 'type' => 'integer' }
                           },
                           'required' => %w[title]
                         })
    end

    it 'coerces a nested data structure' do
      payload = {
        name: 'Ismael',
        age: '42',
        friend: {
          name: 'Joe'
        },
        tags: [10, 'foo'],
        friends: [
          { name: 'Joan', age: 44 },
          { age: '45' }
        ]
      }

      assert_result(
        schema.resolve(payload),
        {
          title: 'Mr',
          name: 'Ismael',
          age: 42,
          friend: {
            name: 'Joe'
          },
          tags: %w[10 foo],
          friends: [
            { name: 'Joan', age: 44 },
            { name: 'Anonymous', age: 45 }
          ]
        },
        true
      )

      invalid_friends = {
        name: 'Joe',
        age: 44,
        friend: { name: 'Ismael' },
        tags: [],
        friends: [{ fo: 'nope' }]
      }

      result = schema.resolve(invalid_friends)
      expect(result.valid?).to be(false)
    end

    it 'works with Array and optional block for element schema' do
      schema = described_class.new do |sc|
        sc.field :friends, Array do |f|
          f.field :name, String
        end
        sc.field :tags, Array # Array of anything
      end

      assert_result(
        schema.resolve(friends: [{ name: 'Joe' }], tags: ['foo', 10]),
        { friends: [{ name: 'Joe' }], tags: ['foo', 10] },
        true
      )

      assert_result(
        schema.resolve(friends: [{ name: 10 }], tags: ['foo', 10]),
        { friends: [{ name: 10 }], tags: ['foo', 10] },
        false
      )
    end

    it 'returns errors for invalid data' do
      result = schema.resolve({ friend: {} })
      expect(result.valid?).to be false
      expect(result.errors[:name]).to eq('Must be a String')
      expect(result.errors[:friend][:name]).to eq('Must be a String')
    end

    specify '#fields' do
      field = schema.fields[:name]
      expect(field.key).to eq(:name)
    end
  end

  specify 'optional keys' do
    schema = described_class.new do |s|
      s.field(:name, Types::String)
      s.field?(:age, Types::Lax::Integer)
    end

    assert_result(schema.resolve({ name: 'Ismael', age: '42' }), { name: 'Ismael', age: 42 }, true)
    assert_result(schema.resolve({ name: 'Ismael' }), { name: 'Ismael' }, true)
  end

  specify 'reusing schemas' do
    friend_schema = described_class.new do |s|
      s.field(:name, Types::String)
    end

    schema = described_class.new do |sc|
      sc.field(:title, Types::String).default('Mr')
      sc.field(:name, Types::String)
      sc.field?(:age, Types::Lax::Integer)
      sc.field(:friend, friend_schema)
    end

    assert_result(schema.resolve({ name: 'Ismael', age: '42', friend: { name: 'Joe' } }),
                  { title: 'Mr', name: 'Ismael', age: 42, friend: { name: 'Joe' } }, true)
  end

  specify 'array schemas with rules' do
    s1 = described_class.new do |sc|
      sc.field(:friends, Types::Array) do |f|
        f.field(:name, Types::String)
      end.policy(size: (1..))
    end

    result = s1.resolve(friends: [{ name: 'Joe' }])
    expect(result.valid?).to be true

    result = s1.resolve(friends: [])
    expect(result.valid?).to be false
  end

  specify 'array schemas literal [] notation' do
    s1 = described_class.new do |sc|
      sc.field(:friends, []) do |f|
        f.field(:name, Types::String)
      end
    end

    result = s1.resolve(friends: [{ name: 'Joe' }])
    expect(result.valid?).to be true
  end

  specify 'fields with primitive types' do
    s1 = described_class.new do |sc|
      sc.field :name, String
      sc.field(:age, Integer).default(10)
      sc.field(:friends, Array) do |f|
        f.field(:name, Types::String)
      end
    end

    result = s1.resolve(name: 'Joe', friends: [{ name: 'Joe' }])
    expect(result.valid?).to be true
    expect(result.value).to eq(name: 'Joe', age: 10, friends: [{ name: 'Joe' }])

    result = s1.resolve(name: 'Joe', friends: ['nope'])
    expect(result.valid?).to be false
  end

  specify 'merge with #+' do
    s1 = described_class.new do |sc|
      sc.field(:name, Types::String)
    end
    s2 = described_class.new do |sc|
      sc.field?(:name, Types::String)
      sc.field(:age, Types::Integer).default(10)
    end
    s3 = s1 + s2
    assert_result(s3.resolve({}), { age: 10 }, true)
    assert_result(s3.resolve(name: 'Joe', foo: 1), { name: 'Joe', age: 10 }, true)

    s4 = s1.merge(s2)
    assert_result(s4.resolve(name: 'Joe', foo: 1), { name: 'Joe', age: 10 }, true)

    expect(s3.fields[:name].key).to eq(:name)
  end

  specify '#merge' do
    s1 = described_class.new do |sc|
      sc.field(:name, Types::String)
    end
    s2 = s1.merge do |sc|
      sc.field?(:age, Types::Integer)
    end
    assert_result(s2.resolve(name: 'Joe'), { name: 'Joe' }, true)
    assert_result(s2.resolve(name: 'Joe', age: 20), { name: 'Joe', age: 20 }, true)
  end

  specify '#&' do
    s1 = described_class.new do |sc|
      sc.field(:name, Types::String)
      sc.field?(:title, Types::String)
      sc.field?(:age, Types::Integer)
    end

    s2 = described_class.new do |sc|
      sc.field(:name, Types::String)
      sc.field?(:age, Types::Integer)
      sc.field?(:email, Types::String)
    end

    s3 = s1 & s2
    assert_result(s3.resolve(name: 'Joe', age: 20, title: 'Mr', email: 'email@me.com'), { name: 'Joe', age: 20 }, true)
  end

  describe '#before' do
    it 'runs before schema fields' do
      populate_name = ->(result) { result.valid(result.value.merge(name: 'Ismael')) }

      schema = described_class.new do |sc|
        # As block
        sc.before do |result|
          result.valid(result.value.merge(title: 'Dr'))
        end
        # As callable
        sc.before populate_name

        sc.field(:title, Types::String).default('Mr')
        sc.field(:name, Types::String)
      end

      assert_result(schema.resolve({}), { title: 'Dr', name: 'Ismael' }, true)
    end

    it 'can halt processing' do
      schema = described_class.new do |sc|
        sc.before do |result|
          result.invalid(errors: 'Halted')
        end

        sc.field(:title, Types::String).default('Mr')
        sc.field(:name, Types::String)
      end

      result = schema.resolve({})
      expect(result.valid?).to be false
      expect(result.value).to eq({})
      expect(result.errors).to eq('Halted')
    end
  end

  describe '#after' do
    it 'runs after schema fields' do
      change_name = ->(result) { result.valid(result.value.merge(name: 'Ismael')) }

      schema = described_class.new do |sc|
        # As callable
        sc.before change_name

        sc.field(:title, Types::String).default('Mr')
        sc.field(:name, Types::String)
      end

      assert_result(schema.resolve({ name: 'Joe' }), { title: 'Mr', name: 'Ismael' }, true)
    end

    it 'can halt processing' do
      schema = described_class.new do |sc|
        sc.before do |result|
          result.invalid(errors: 'Halted')
        end

        sc.field(:title, Types::String).default('Mr')
        sc.field(:name, Types::String)
      end

      result = schema.resolve({})
      expect(result.valid?).to be false
      expect(result.value).to eq({})
      expect(result.errors).to eq('Halted')
    end
  end

  specify 'Field#meta' do
    field = described_class::Field.new(:name, Types::String).metadata(foo: 1).metadata(bar: 2)
    expect(field.metadata).to eq(type: ::String, foo: 1, bar: 2)
    expect(field.metadata).to eq(field.metadata)
  end

  specify 'Field#options' do
    field = described_class::Field.new(:name, Types::String).options(%w[aa bb cc])
    assert_result(field.resolve('aa'), 'aa', true)
    assert_result(field.resolve('cc'), 'cc', true)
    assert_result(field.resolve('dd'), 'dd', false)
    expect(field.metadata[:options]).to eq(%w[aa bb cc])
  end

  specify 'Field#nullable' do
    field = described_class::Field.new(:name, Types::String.transform(::String) do |v|
                                                "Hello #{v}"
                                              end).nullable
    assert_result(field.resolve('Ismael'), 'Hello Ismael', true)
    assert_result(field.resolve(nil), nil, true)
  end

  specify 'Field#present' do
    field = described_class::Field.new(:name).present
    assert_result(field.resolve('Ismael'), 'Ismael', true)
    assert_result(field.resolve(nil), nil, false)
    expect(field.resolve(nil).errors).to eq('must be present')
  end

  specify 'Field#required' do
    field = described_class::Field.new(:name).required
    assert_result(field.resolve, Plumb::Undefined, false)
    assert_result(field.resolve(nil), nil, true)
    expect(field.resolve.errors).to eq('is required')
  end

  specify 'Field#default' do
    field = described_class::Field.new(:friends, Types::Array[Types::String]).default([].freeze)
    assert_result(field.resolve, [], true)
  end

  specify 'Field#match' do
    field = described_class::Field.new(:age, Integer).match(21..)
    assert_result(field.resolve(22), 22, true)
    assert_result(field.resolve(20), 20, false)
  end

  specify 'self-contained Array type' do
    array_type = Types::Array[Types::Integer | Types::String.transform(::Integer, &:to_i)]
    schema = described_class.new do |sc|
      sc.field(:numbers, array_type)
    end

    assert_result(schema.resolve(numbers: [1, 2, '3']), { numbers: [1, 2, 3] }, true)
  end
end

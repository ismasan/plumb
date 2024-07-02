# frozen_string_literal: true

require 'spec_helper'
require 'plumb'

RSpec.describe Plumb::JSONSchemaVisitor do
  subject(:visitor) { described_class }

  specify 'simplest possible case with one-level keys and types' do
    type = Types::Hash[
      name: Types::String.meta(description: 'the name'),
      age?: Types::Integer
    ]

    expect(described_class.call(type)).to eq(
      {
        '$schema' => 'https://json-schema.org/draft-08/schema#',
        'type' => 'object',
        'properties' => {
          'name' => { 'type' => 'string', 'description' => 'the name' },
          'age' => { 'type' => 'integer' }
        },
        'required' => %w[name]
      }
    )
  end

  describe 'building properties' do
    specify 'Hash with key and value types' do
      type = Types::Hash.schema(
        Types::String,
        Types::Integer
      )

      expect(described_class.visit(type)).to eq(
        'type' => 'object',
        'patternProperties' => { '.*' => { 'type' => 'integer' } }
      )
    end

    specify 'Types::String' do
      type = Types::String
      expect(described_class.visit(type)).to eq('type' => 'string')
    end

    specify 'Types::Integer' do
      type = Types::Integer
      expect(described_class.visit(type)).to eq('type' => 'integer')
    end

    specify 'Types::Numeric' do
      type = Types::Numeric
      expect(described_class.visit(type)).to eq('type' => 'number')
    end

    specify 'Types::Decimal' do
      type = Types::Decimal
      expect(described_class.visit(type)).to eq('type' => 'number')
    end

    specify 'Float' do
      type = Types::Any[Float]
      expect(described_class.visit(type)).to eq('type' => 'number')
    end

    specify 'Not' do
      type = Types::Decimal.not
      expect(described_class.visit(type)).to eq('not' => { 'type' => 'number' })
    end

    specify 'Types::Match with RegExp' do
      type = Types::String[/[a-z]+/]
      expect(described_class.visit(type)).to eq('type' => 'string', 'pattern' => '[a-z]+')
    end

    specify 'Types::Match with Range' do
      type = Types::Integer[10..100]
      expect(described_class.visit(type)).to eq('type' => 'integer', 'minimum' => 10, 'maximum' => 100)

      type = Types::Integer[10...100]
      expect(described_class.visit(type)).to eq('type' => 'integer', 'minimum' => 10, 'maximum' => 99)

      type = Types::Integer[10..]
      expect(described_class.visit(type)).to eq('type' => 'integer', 'minimum' => 10)

      type = Types::Integer[..100]
      expect(described_class.visit(type)).to eq('type' => 'integer', 'maximum' => 100)
    end

    specify '#default' do
      # JSON schema's semantics for default values means a default only applies
      # when the key is missing from the payload.
      type = Types::String.default('foo')
      expect(described_class.visit(type)).to eq('type' => 'string', 'default' => 'foo')

      type = Types::String | (Types::Undefined >> Types::Static['bar'])
      expect(described_class.visit(type)).to eq('type' => 'string', 'default' => 'bar')

      type = (Types::Undefined >> Types::Static['bar2']) | Types::String
      expect(described_class.visit(type)).to eq('type' => 'string', 'default' => 'bar2')
    end

    specify '#match' do
      type = Types::String.match(/[a-z]+/)
      expect(described_class.visit(type)).to eq('type' => 'string', 'pattern' => '[a-z]+')
    end

    specify '#build' do
      type = Types::Any.build(::String)
      expect(described_class.visit(type)).to eq('type' => 'string')
    end

    specify 'Types::String >> Types::Integer' do
      type = Types::String >> Types::Integer
      expect(described_class.visit(type)).to eq('type' => 'integer')
    end

    specify 'Types::String | Types::Integer' do
      type = Types::String | Types::Integer
      expect(described_class.visit(type)).to eq(
        'anyOf' => [{ 'type' => 'string' }, { 'type' => 'integer' }]
      )
    end

    specify 'complex type with AND and OR branches' do
      type = Types::String \
        | (Types::Integer.transform(::Integer) { |v| v * 2 }).options([2, 4])

      expect(visitor.visit(type)).to eq(
        'anyOf' => [
          { 'type' => 'string' },
          { 'type' => 'integer', 'enum' => [2, 4] }
        ]
      )
    end

    specify 'Types::Array' do
      type = Types::Array[Types::String]
      expect(described_class.visit(type)).to eq(
        'type' => 'array',
        'items' => { 'type' => 'string' }
      )
    end

    specify 'Types::Boolean' do
      type = Types::Boolean
      expect(described_class.visit(type)).to eq('type' => 'boolean')
    end

    specify 'Types.nullable' do
      type = Types::String.nullable.default('bar')
      expect(described_class.visit(type)).to eq(
        'anyOf' => [{ 'type' => 'null' }, { 'type' => 'string' }],
        'default' => 'bar'
      )
    end

    specify 'Types::True' do
      type = Types::True
      expect(described_class.visit(type)).to eq('type' => 'boolean')
    end

    specify 'Pipeline' do
      type = Types::String.pipeline do |pl|
        pl.step { |result| result }
      end
      expect(described_class.visit(type)).to eq('type' => 'string')
    end

    specify 'Types::Array with union member type' do
      type = Types::Array[
        Types::String | Types::Hash.schema(
          name: Types::String
        )
      ]

      expect(described_class.visit(type)).to eq(
        'type' => 'array',
        'items' => {
          'anyOf' => [
            { 'type' => 'string' },
            {
              'type' => 'object',
              'properties' => {
                'name' => { 'type' => 'string' }
              },
              'required' => ['name']
            }
          ]
        }
      )
    end

    specify 'Types::Tuple' do
      type = Types::Tuple[
        'ok',
        Types::String,
        Types::Integer
      ]

      expect(described_class.visit(type)).to eq(
        'type' => 'array',
        'prefixItems' => [
          { 'const' => 'ok', 'type' => 'string' },
          { 'type' => 'string' },
          { 'type' => 'integer' }
        ]
      )
    end

    specify 'Types::Hash.tagged_by' do
      t1 = Types::Hash[
        kind: Types::Static['t1'], name: Types::String,
        age: Types::Integer
      ]
      t2 = Types::Hash[kind: Types::Static['t2'], name: Types::String]
      type = Types::Hash.tagged_by(:kind, t1, t2)

      expect(described_class.visit(type)).to eq(
        'type' => 'object',
        'properties' => {
          'kind' => { 'type' => 'string', 'enum' => %w[t1 t2] }
        },
        'required' => ['kind'],
        'allOf' => [
          {
            'if' => {
              'properties' => {
                'kind' => { 'const' => 't1', 'type' => 'string' }
              }
            },
            'then' => {
              'properties' => {
                'kind' => { 'type' => 'string', 'default' => 't1', 'const' => 't1' },
                'name' => { 'type' => 'string' },
                'age' => { 'type' => 'integer' }
              },
              'required' => %w[kind name age]
            }
          },
          {
            'if' => {
              'properties' => {
                'kind' => { 'const' => 't2', 'type' => 'string' }
              }
            },
            'then' => {
              'properties' => {
                'kind' => { 'type' => 'string', 'default' => 't2', 'const' => 't2' },
                'name' => { 'type' => 'string' }
              },
              'required' => %w[kind name]
            }
          }
        ]
      )
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'

# Typed hash keys and the `_` catch-all (replacing HashClass#inclusive). See
# lib/plumb/key.rb and HashClass#call / #&.
RSpec.describe 'typed hash keys and the `_` catch-all' do
  module KTypes
    include Plumb::Types
  end

  describe 'catch-all value semantics' do
    it '`_: Any` keeps undeclared keys unchanged' do
      t = KTypes::Hash[a: KTypes::String, _: KTypes::Any]
      assert_result(t.resolve({ a: 'x', b: 1, c: [1, 2] }), { a: 'x', b: 1, c: [1, 2] }, true)
    end

    it '`_: T` validates undeclared values against T' do
      t = KTypes::Hash[a: KTypes::String, _: KTypes::Integer]
      assert_result(t.resolve({ a: 'x', b: 1 }), { a: 'x', b: 1 }, true)
      expect(t.resolve({ a: 'x', b: 'nope' }).valid?).to be(false)
    end

    it 'coerces undeclared values through a coercing catch-all' do
      t = KTypes::Hash[a: KTypes::String, _: KTypes::Lax::Integer]
      assert_result(t.resolve({ a: 'x', b: '10' }), { a: 'x', b: 10 }, true)
    end

    it 'still validates declared keys' do
      t = KTypes::Hash[a: KTypes::String, _: KTypes::Any]
      expect(t.resolve({ a: 1, b: 2 }).valid?).to be(false)
    end
  end

  describe 'drop default (no catch-all)' do
    it 'drops undeclared keys silently' do
      assert_result(KTypes::Hash[a: KTypes::String].resolve({ a: 'x', b: 1 }), { a: 'x' }, true)
    end
  end

  describe 'string and typed keys' do
    it 'supports String literal keys' do
      t = KTypes::Hash['name' => KTypes::String]
      assert_result(t.resolve({ 'name' => 'x' }), { 'name' => 'x' }, true)
    end

    it 'supports a pattern/type key + catch-all' do
      t = KTypes::Hash[KTypes::String[/^id_/] => KTypes::Integer, _: KTypes::Any]
      assert_result(t.resolve({ 'id_a' => 1, 'other' => 'y' }), { 'id_a' => 1, 'other' => 'y' }, true)
      expect(t.resolve({ 'id_a' => 'no' }).valid?).to be(false)
    end
  end

  describe 'intersection (#&)' do
    it 'admits the other side keys through a catch-all' do
      a = KTypes::Hash[a: KTypes::String, _: KTypes::Any]
      b = KTypes::Hash[a: KTypes::String, b: KTypes::Integer]
      expect(a & b).to eq(KTypes::Hash[a: KTypes::String, b: KTypes::Integer])
    end

    it 'meets two catch-alls' do
      a = KTypes::Hash[_: KTypes::Integer]
      b = KTypes::Hash[_: KTypes::Integer[0..10]]
      expect(a & b).to eq(KTypes::Hash[_: KTypes::Integer[0..10]])
    end

    it 'is Never for two closed schemas that share no keys' do
      expect(KTypes::Hash[a: KTypes::Integer] & KTypes::Hash[b: KTypes::String]).to eq(KTypes::Never)
    end
  end

  describe 'subtyping / composition' do
    it 'a closed Hash is a subtype of an open (catch-all Any) Hash' do
      expect(KTypes::Hash[a: KTypes::String, name: KTypes::Integer] <= KTypes::Hash[a: KTypes::String, _: KTypes::Any])
        .to be(true)
    end

    it 'an open (catch-all Any) Hash is NOT a subtype of a Symbol-keyed HashMap' do
      expect do
        KTypes::Hash[name: KTypes::Integer, _: KTypes::Any] >> KTypes::Hash[KTypes::Symbol, KTypes::Integer]
      end.to raise_error(Plumb::TypeError)
    end

    it 'a HashMap is a subtype of an open catch-all-only Hash when values fit' do
      expect(KTypes::Hash[KTypes::Symbol, KTypes::Integer] <= KTypes::Hash[_: KTypes::Numeric]).to be(true)
      expect(KTypes::Hash[KTypes::Symbol, KTypes::Numeric] <= KTypes::Hash[_: KTypes::Integer]).to be(false)
    end
  end

  describe 'JSON Schema' do
    it 'renders `_: T` as additionalProperties' do
      schema = KTypes::Hash[a: KTypes::String, _: KTypes::Integer].to_json_schema
      expect(schema['properties']).to eq({ 'a' => { 'type' => 'string' } })
      expect(schema['required']).to eq(['a'])
      expect(schema['additionalProperties']).to eq({ 'type' => 'integer' })
    end

    it 'renders `_: Any` as an open additionalProperties' do
      expect(KTypes::Hash[a: KTypes::String, _: KTypes::Any].to_json_schema['additionalProperties']).to eq({})
    end

    it 'renders a pattern key as patternProperties' do
      schema = KTypes::Hash[KTypes::String[/^id_/] => KTypes::Integer].to_json_schema
      expect(schema['patternProperties']).to eq({ '^id_' => { 'type' => 'integer' } })
    end
  end

  describe 'inspect' do
    it 'renders the catch-all as `_`' do
      expect(KTypes::Hash[a: KTypes::String, _: KTypes::Any].inspect).to include('_: ')
    end
  end
end

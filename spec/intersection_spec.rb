# frozen_string_literal: true

require 'set'
require 'spec_helper'

# The `#&` intersection operator (the meet / greatest lower bound) and the
# `Types::Never` bottom type. See Plumb::Subtyping.intersect and NeverClass.
RSpec.describe 'intersection (#&) and Never' do
  module ITypes
    include Plumb::Types
  end

  describe 'Range intersection' do
    it 'narrows two overlapping ranges to their overlap' do
      expect(ITypes::Integer[2..] & ITypes::Integer[0..100]).to eq(ITypes::Integer[2..100])
    end

    it 'is order-independent (commutative)' do
      a = ITypes::Integer[2..] & ITypes::Integer[0..100]
      b = ITypes::Integer[0..100] & ITypes::Integer[2..]
      expect(a).to eq(b)
    end

    it 'validates the intersected range' do
      type = ITypes::Integer[2..] & ITypes::Integer[0..100]
      assert_result(type.resolve(50), 50, true)
      assert_result(type.resolve(1), 1, false)
      assert_result(type.resolve(101), 101, false)
    end

    it 'collapses a disjoint range intersection to Never' do
      type = ITypes::Integer[2..10] & ITypes::Integer[11..100]
      expect(type).to eq(ITypes::Never)
      assert_result(type.resolve(5), 5, false)
    end
  end

  describe 'Set intersection' do
    it 'intersects two membership sets' do
      expect(ITypes::Integer[Set[1, 2, 3]] & ITypes::Integer[Set[2, 3, 4]])
        .to eq(ITypes::Integer[Set[2, 3]])
    end

    it 'collapses an empty set intersection to Never' do
      expect(ITypes::Integer[Set[1, 2]] & ITypes::Integer[Set[3, 4]]).to eq(ITypes::Never)
    end
  end

  describe 'disjoint base classes' do
    it 'collapses String & Integer to Never' do
      expect(ITypes::String & ITypes::Integer).to eq(ITypes::Never)
    end
  end

  describe 'subtype absorption' do
    it 'keeps the narrower operand' do
      expect(ITypes::Integer & ITypes::Numeric).to eq(ITypes::Integer)
      expect(ITypes::Numeric & ITypes::Integer).to eq(ITypes::Integer)
      expect(ITypes::Integer[5] & ITypes::Integer).to eq(ITypes::Integer[5])
    end
  end

  describe 'distribution over unions and Never absorption' do
    it 'drops a Never branch: Integer | (String & Integer) == Integer' do
      expect(ITypes::Integer | (ITypes::String & ITypes::Integer)).to eq(ITypes::Integer)
    end

    it 'distributes: (Integer | String) & String == String' do
      expect((ITypes::Integer | ITypes::String) & ITypes::String).to eq(ITypes::String)
    end
  end

  describe 'covariant containers' do
    it 'intersects Array element types' do
      expect(ITypes::Array[ITypes::Integer | ITypes::Float] & ITypes::Array[ITypes::Float])
        .to eq(ITypes::Array[ITypes::Float])
    end

    it 'collapses to Never when the element intersection is empty' do
      expect(ITypes::Array[ITypes::Integer] & ITypes::Array[ITypes::String]).to eq(ITypes::Never)
    end

    it 'intersects Tuple positions (same arity)' do
      expect(ITypes::Tuple[ITypes::Integer[0..10], ITypes::String] &
             ITypes::Tuple[ITypes::Integer[5..20], ITypes::String])
        .to eq(ITypes::Tuple[ITypes::Integer[5..10], ITypes::String])
    end

    it 'intersects HashMap key/value types' do
      expect(ITypes::Hash[ITypes::String, ITypes::Integer[0..10]] &
             ITypes::Hash[ITypes::String, ITypes::Integer[5..20]])
        .to eq(ITypes::Hash[ITypes::String, ITypes::Integer[5..10]])
    end
  end

  describe 'Hash (key-set join with per-field meet) and non-Hash' do
    it 'keeps keys present in both' do
      s1 = ITypes::Hash.schema(name: ITypes::String, age: ITypes::Integer, company: ITypes::String)
      s2 = ITypes::Hash.schema(name?: ITypes::String, age: ITypes::Integer, email: ITypes::String)
      s3 = s1 & s2
      assert_result(s3.resolve(name: 'Ismael', age: 42, company: 'ACME', email: 'me@acme.com'),
                    { name: 'Ismael', age: 42 }, true)
    end

    it 'intersects the field types of shared keys' do
      s1 = ITypes::Hash[age: ITypes::Integer[1..20], name: ITypes::String]
      s2 = ITypes::Hash[age: ITypes::Integer[0..10]]
      expect(s1 & s2).to eq(ITypes::Hash[age: ITypes::Integer[1..10]])
    end

    it 'yields a Never field when a shared key intersects to empty' do
      s1 = ITypes::Hash[age: ITypes::Integer[1..5]]
      s2 = ITypes::Hash[age: ITypes::Integer[10..20]]
      expect(s1 & s2).to eq(ITypes::Hash[age: ITypes::Never])
      # A required Never field makes the hash uninhabitable.
      assert_result((s1 & s2).resolve(age: 3), { age: 3 }, false)
      assert_result((s1 & s2).resolve({}), {}, false)
    end

    it 'is Never when intersected with a non-Hash type' do
      expect(ITypes::Hash[name: ITypes::String] & ITypes::Integer).to eq(ITypes::Never)
    end

    it 'is Never when two non-empty schemas share no keys' do
      expect(ITypes::Hash[a: ITypes::Integer] & ITypes::Hash[b: ITypes::String]).to eq(ITypes::Never)
    end

    it 'treats the empty-schema (any) Hash as the intersection identity' do
      any = ITypes::Hash.schema({})
      expect(any & ITypes::Hash[a: ITypes::Integer]).to eq(ITypes::Hash[a: ITypes::Integer])
      expect(ITypes::Hash[a: ITypes::Integer] & any).to eq(ITypes::Hash[a: ITypes::Integer])
      expect(any & any).to eq(any)
    end
  end

  describe 'runtime And fallback' do
    it 'validates through both sides when it cannot prove a reduction' do
      even = ITypes::Integer.check('even') { |v| v.even? }
      type = ITypes::Integer & even
      assert_result(type.resolve(4), 4, true)
      assert_result(type.resolve(3), 3, false)
    end
  end

  describe 'Never identities' do
    it 'Any & X == X' do
      expect(ITypes::Any & ITypes::Integer).to eq(ITypes::Integer)
    end

    it 'X & Never == Never and Never & X == Never' do
      expect(ITypes::Integer & ITypes::Never).to eq(ITypes::Never)
      expect(ITypes::Never & ITypes::Integer).to eq(ITypes::Never)
    end

    it 'X | Never == X and Never | X == X' do
      expect(ITypes::Integer | ITypes::Never).to eq(ITypes::Integer)
      expect(ITypes::Never | ITypes::Integer).to eq(ITypes::Integer)
    end

    it 'Never >> X == Never' do
      expect(ITypes::Never >> ITypes::Integer).to eq(ITypes::Never)
    end

    it 'never validates any value' do
      assert_result(ITypes::Never.resolve(5), 5, false)
      assert_result(ITypes::Never.resolve('x'), 'x', false)
      assert_result(ITypes::Never.resolve(nil), nil, false)
    end
  end

  describe 'Never subtyping' do
    it 'is a subtype of everything' do
      expect(ITypes::Never <= ITypes::Integer).to be(true)
      expect(ITypes::Never <= ITypes::Any).to be(true)
      expect(ITypes::Never <= ITypes::Never).to be(true)
    end

    it 'nothing but Never is a subtype of Never' do
      expect(ITypes::Integer <= ITypes::Never).to be(false)
      expect(ITypes::Any <= ITypes::Never).to be(false)
    end
  end

  describe 'visitors' do
    it 'renders JSON Schema as a never-matching schema' do
      expect(ITypes::Never.to_json_schema).to eq({ 'not' => {} })
    end

    it 'has no user metadata' do
      expect(ITypes::Never.metadata).to eq({})
    end
  end
end

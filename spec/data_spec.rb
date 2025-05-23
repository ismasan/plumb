# frozen_string_literal: true

require 'spec_helper'

module Types
  class User < Types::Data
    class Company < Types::Data
      attribute :name, String
    end

    attribute :name, String
    attribute :age, Integer[18..]
    attribute :friend do
      attribute :name, String
      attribute :email, String[/.+@.+/]
    end
    attribute :company, Company
    attribute :books, Array.default([].freeze) do
      attribute :isbn, String
    end

    def book_count = books.size
  end

  class StaffMember < Types::Data
    attribute :name, String
    attribute :age, Lax::Integer[18..]
  end

  class Office < Types::Data
    attribute? :director, StaffMember
    attribute :staff, Array[StaffMember].default([].freeze)
  end

  class OfficeWithAddress < Office
    attribute :address do
      attribute :street, String.present
      attribute :city, String.present
    end
  end

  class DifferentClass
    include Plumb::Attributes
    attribute :name, String
    attribute :thing do
      attribute :name, String
    end
  end
end

RSpec.describe Types::Data do
  specify 'setting nested classes' do
    expect(Types::User::Friend).to be_a(Class)
    friend = Types::User::Friend.new(name: 'John', email: 'john@server.com')
    expect(friend.name).to eq 'John'
  end

  specify 'valid' do
    user = Types::User.new(
      name: 'Jane',
      age: 20,
      friend: { name: 'John', email: 'john@server.com' },
      company: { name: 'Acme' },
      books: [{ isbn: '123' }]
    )
    expect(user.name).to eq 'Jane'
    expect(user.age).to eq 20
    expect(user.valid?).to be true
    expect(user.friend.name).to eq 'John'
    expect(user.friend.email).to eq 'john@server.com'
    expect(user.friend).to be_a(Types::User::Friend)
    expect(user.company.name).to eq 'Acme'
    expect(user.books.map(&:isbn)).to eq ['123']
    expect(user.book_count).to eq 1
    expect(user.books.first).to be_a(Types::User::Book)
  end

  specify 'invalid with non-hash value' do
    expect do
      Types::User.new(1)
    end.to raise_error(ArgumentError)
  end

  specify '#to_h' do
    user = Types::User.new(
      name: 'Jane',
      age: 20,
      friend: { name: 'John', email: 'john@server.com' },
      company: { name: 'Acme' },
      books: [{ isbn: '123' }]
    )
    expect(user.to_h).to eq(
      name: 'Jane',
      age: 20,
      friend: { name: 'John', email: 'john@server.com' },
      company: { name: 'Acme' },
      books: [{ isbn: '123' }]
    )
    nillable = Types::Data[foo: Types::String.nullable, count?: Integer]
    expect(nillable.new(foo: nil, count: 10).to_h).to eq(foo: nil, count: 10)
    expect(nillable.new(foo: nil).to_h).to eq(foo: nil, count: nil)
  end

  specify '#to_hash' do
    user = Types::User.new(
      name: 'Jane',
      age: 20,
      friend: { name: 'John', email: 'john@server.com' },
      company: { name: 'Acme' },
      books: [{ isbn: '123' }]
    )

    expect(user.to_hash).to eq(user.to_h)
  end

  describe '#==' do
    specify 'nested structs' do
      user1 = Types::User.new(
        name: 'Jane',
        age: 20,
        friend: { name: 'John', email: 'john@server.com' },
        company: { name: 'Acme' },
        books: [{ isbn: '123' }]
      )
      user2 = Types::User.new(
        name: 'Jane',
        age: 20,
        friend: { name: 'John', email: 'john@server.com' },
        company: { name: 'Acme' },
        books: [{ isbn: '123' }]
      )
      user3 = Types::User.new(
        name: 'Jane',
        age: 20,
        friend: { name: 'Phil', email: 'phil@server.com' },
        company: { name: 'Acme' },
        books: [{ isbn: '123' }]
      )

      expect(user1 == user2).to be true
      expect(user1 == user3).to be false
    end

    specify 'optional keys' do
      klass = Types::Data[foo?: Types::String.nullable, age: Integer]
      k1 = klass.new(age: 20, foo: nil)
      k2 = klass.new(age: 20)
      expect(k1 == k2).to be false
    end
  end

  describe 'pattern matching' do
    let(:user) do
      Types::User.new(
        name: 'Jane',
        age: 20,
        friend: { name: 'John', email: 'john@server.com' },
        company: { name: 'Acme' },
        books: [{ isbn: '123' }]
      )
    end

    specify '#deconstruct' do
      expect(user.deconstruct).to eq(['Jane', 20, { email: 'john@server.com', name: 'John' }, { name: 'Acme' },
                                      [{ isbn: '123' }]])
    end

    specify '#deconstruct_keys' do
      expect(user.deconstruct_keys(nil)).to eq(user.to_h)
    end
  end

  specify 'optional attributes' do
    office = Types::Office.new(staff: [])
    expect(office.valid?).to be true
    expect(office.director).to eq(nil)

    office = Types::Office.new(director: { name: 'Mr. Burns', age: 100 }, staff: [])
    expect(office.valid?).to be true
    expect(office.director).to eq(Types::StaffMember.new(name: 'Mr. Burns', age: 100))
  end

  specify 'Types::Array[Data].default()' do
    office = Types::Office.new(staff: [{ name: 'Jane', age: '20' }])
    office2 = Types::Office.new
    expect(office.valid?).to be true
    expect(office.staff.first.name).to eq 'Jane'
    expect(office.staff.first.age).to eq 20
    expect(office2.staff).to eq []
  end

  specify 'Types::Array[Data].default() with errors' do
    office = Types::Office.new(staff: [{ name: 'Jane' }])
    expect(office.valid?).to be false
    expect(office.staff.first.name).to eq 'Jane'
    expect(office.staff.first.valid?).to be(false)
    expect(office.staff.first.errors[:age]).not_to be_empty
  end

  specify 'shorthand typed array syntax' do
    klass = Class.new(Types::Data) do
      attribute :typed_array, [Integer]
      attribute :untyped_array, []
      attribute :data_array, [] do
        attribute :name, String
      end
    end

    thing = klass.new(typed_array: [1, 2, 3], untyped_array: [1, 'hello'], data_array: [{ name: 'foo' }])
    expect(thing.typed_array).to eq([1, 2, 3])
    expect(thing.untyped_array).to eq([1, 'hello'])
    expect(thing.data_array.map(&:name)).to eq(['foo'])
    expect(thing.valid?).to be(true)
    thing = klass.new(typed_array: [1, 2, '3'])
    expect(thing.valid?).to be(false)
  end

  specify 'invalid shorthard array with multiple elements' do
    expect do
      Class.new(Types::Data) do
        attribute :typed_array, [Integer, String]
      end
    end.to raise_error(ArgumentError)
  end

  specify 'invalid' do
    user = Types::User.new(
      name: 'Jane',
      age: 20,
      friend: { name: 'John', email: 'nope' }
    )
    expect(user.name).to eq 'Jane'
    expect(user.age).to eq 20
    expect(user.valid?).to be false
    expect(user.friend.name).to eq 'John'
    expect(user.friend.email).to eq 'nope'
    expect(user.errors[:friend][:email]).to eq('Must match /.+@.+/')
    expect(user.friend.errors[:email]).to eq('Must match /.+@.+/')
    expect(user.errors[:company]).to eq(['Must be a Hash of attributes'])
  end

  specify '#with' do
    user1 = Types::StaffMember.new(name: 'Jane', age: 20)
    user2 = user1.with(name: 'John')
    expect(user1.name).to eq 'Jane'
    expect(user1.age).to eq 20
    expect(user2.name).to eq 'John'
    expect(user2.age).to eq 20
  end

  specify 'inheritance' do
    office = Types::OfficeWithAddress.new(
      director: { name: 'Mr. Burns', age: 100 },
      staff: [{ name: 'Jane', age: 20 }],
      address: { street: '123 Main St', city: 'Springfield' }
    )
    expect(office.staff).to eq([Types::StaffMember.new(name: 'Jane', age: 20)])
    expect(office.address.street).to eq '123 Main St'
    expect(office.address.city).to eq 'Springfield'
    expect(office.director).to eq(Types::StaffMember.new(name: 'Mr. Burns', age: 100))
  end

  specify '.[]' do
    office_with_phone_klass = Types::Office[phone: String, kind?: String]
    office = office_with_phone_klass.new(
      director: { name: 'Mr. Burns', age: 100 },
      staff: [{ name: 'Jane', age: 20 }],
      phone: '555-1234'
    )
    expect(office.staff).to eq([Types::StaffMember.new(name: 'Jane', age: 20)])
    expect(office.phone).to eq '555-1234'
    expect(office.kind).to be(nil)
    office2 = office.with(kind: 'bar')
    expect(office2.kind).to eq 'bar'
  end

  describe 'Composable' do
    it 'is composable' do
      expect(Types::User).to be_a(Plumb::Composable)
    end

    specify '.resolve with hash attributes' do
      assert_result(
        Types::StaffMember.resolve(name: 'Jane', age: 20),
        Types::StaffMember.new(name: 'Jane', age: 20),
        true
      )
    end

    specify '.resolve with instance' do
      instance = Types::StaffMember.new(name: 'Jane', age: 20)

      assert_result(
        Types::StaffMember.resolve(instance),
        Types::StaffMember.new(name: 'Jane', age: 20),
        true
      )
    end

    specify '.metadata[:type]' do
      type = Types::StaffMember | Types::User
      expect(type.metadata[:type]).to eq([Types::StaffMember, Types::User])
    end
  end

  specify 'defining from Types::Hash' do
    hash = Types::Hash[name: String, age?: Integer]
    data = Types::Data[hash]
    instance = data.new(name: 'Joe')
    expect(instance.name).to eq('Joe')
    expect(instance.age).to be(nil)
  end

  specify 'a different class that includes Plumb::Attributes' do
    instance = Types::DifferentClass.new(name: 'Joe', thing: { name: 'foo' })
    expect(instance.name).to eq('Joe')
    expect(instance.thing.name).to eq('foo')
    expect(instance.thing).to be_a(Types::DifferentClass)
    expect(instance.thing).to be_a(Types::DifferentClass::Thing)
  end

  specify 'Data.===(instance)' do
    class_a = Types::Data[name: String]
    class_b = Types::Data[name: String]
    a = class_a.new(name: 'Joe')
    expect(class_a === a).to be true
    expect(class_b === a).to be false
  end

  specify 'private attributes' do
    klass = Class.new(Types::Data) do
      attribute :name, String
      private attribute :age, Integer

      def full = "#{name} (#{age})"
    end

    obj = klass.new(name: 'Joe', age: 20)
    expect { obj.age }.to raise_error(NoMethodError)
    expect(obj.full).to eq('Joe (20)')
  end

  specify 'writer: true' do
    klass = Class.new(Types::Data) do
      attribute :host, Types::Forms::URI::HTTP, writer: true
      attribute :port, Types::Lax::Integer.default(80), writer: true
      attribute :thing do
        attribute :name, String, writer: true
      end
    end

    config = klass.new(thing: { name: 'foo' })
    expect(config.valid?).to be false
    expect(config.port).to eq 80

    config.host = 'http://example.com'
    expect(config.valid?).to be true
    expect(config.host).to be_a(URI::HTTP)
    expect(config.thing.name).to eq 'foo'
    expect(config.thing.name = 'bar').to eq 'bar'
    expect(config.thing.name).to eq 'bar'

    config.host = 10
    expect(config.valid?).to be false
    expect(config.errors[:host].any?).to be true
  end
end

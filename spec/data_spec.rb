# frozen_string_literal: true

require 'spec_helper'
require 'plumb'
# require 'plumb/struct'

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
    attribute :books, Array do
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
  end

  specify '#==' do
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
end

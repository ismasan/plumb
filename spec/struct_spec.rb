# frozen_string_literal: true

require 'spec_helper'
require 'plumb'
require 'plumb/struct'

module Types
  class User < Plumb::Struct
    class Company < Plumb::Struct
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

  class StaffMember < Plumb::Struct
    attribute :name, String
    attribute :age, Lax::Integer[18..]
  end

  class Office < Plumb::Struct
    attribute :staff, Array[StaffMember]
  end
end

RSpec.describe Plumb::Struct do
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
    expect(user.company.name).to eq 'Acme'
    expect(user.books.map(&:isbn)).to eq ['123']
    expect(user.book_count).to eq 1
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

  specify 'Array[StructType]' do
    office = Types::Office.new(staff: [{ name: 'Jane', age: '20' }])
    expect(office.valid?).to be true
    expect(office.staff.first.name).to eq 'Jane'
    expect(office.staff.first.age).to eq 20
  end

  specify 'Array[StructType] with errors' do
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
end
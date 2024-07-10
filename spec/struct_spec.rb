# frozen_string_literal: true

require 'spec_helper'
require 'plumb'

module Plumb
  class Struct
    attr_reader :errors, :attributes

    def initialize(attrs = {})
      @errors = {}
      @attributes = self.class.attribute_specs.each_with_object({}) do |(name, type), hash|
        name = name.to_sym
        value = attrs.key?(name) ? attrs[name] : Plumb::Undefined
        result = type.resolve(value)
        @errors[name] = result.errors unless result.valid?
        hash[name] = result.value
      end
    end

    def valid? = errors.none?

    def inspect
      %(#<#{self.class}:#{object_id} #{attributes.map { |k, v| [k, v.inspect].join(': ') }.join(' ')}>)
    end

    class << self
      def call(result)
        return result.invalid(errors: ['Must be a Hash of attributes']) unless result.value.is_a?(Hash)

        instance = new(result.value)
        instance.valid? ? result.valid(instance) : result.invalid(instance, errors: instance.errors)
      end

      def attribute_specs
        @attribute_specs ||= {}
      end

      # attribute(:friend) { attribute(:name, String) }
      # attribute(:friend, MyStruct) { attribute(:name, String) }
      # attribute(:name, String)
      # attribute(:friends, Types::Array) { attribute(:name, String) }
      # attribute(:friends, Types::Array)
      #
      def attribute(name, *args, &block)
        name = name.to_sym

        type = case args
               in [Class => klass] if block_given? # attribute(:friend, MyStruct) { ... }
                 sub = Class.new(klass)
                 sub.instance_exec(&block)
                 __set_nested_class__(name, sub)
                 Plumb::Steppable.wrap(sub)
               in [] if block_given? # attribute(:friend) { ... }
                 sub = Class.new(Plumb::Struct)
                 sub.instance_exec(&block)
                 __set_nested_class__(name, sub)
                 Plumb::Steppable.wrap(sub)
               in [Plumb::ArrayClass => type] if block_given?
                 sub = type.element_type
                 if sub == Plumb::Types::Any
                   sub = Class.new(Plumb::Struct)
                   sub.instance_exec(&block)
                   __set_nested_class__(name, sub)
                   Plumb::Types::Array[Plumb::Steppable.wrap(sub)]
                 else
                   type
                 end
               in [Plumb::Steppable => type] # attribute(:name, String)
                 type
               in [type]
                 Plumb::Steppable.wrap(type)
               else
                 raise ArgumentError, "Invalid arguments: #{args.inspect}"
               end

        attribute_specs[name] = type
        define_method(name) { @attributes[name] }
      end

      def __set_nested_class__(name, klass)
        name = name.to_s.split('_').map(&:capitalize).join.sub(/s$/, '')
        const_set(name, klass) unless const_defined?(name)
      end
    end
  end
end

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

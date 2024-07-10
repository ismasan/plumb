# frozen_string_literal: true

require 'spec_helper'
require 'plumb'

module Plumb
  module Attributes
    def self.included(base)
      base.extend(ClassMethods)
    end

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

    module ClassMethods
      def attribute_specs
        @attribute_specs ||= {}
      end

      def attribute(name, type)
        name = name.to_sym
        type = Plumb::Steppable.wrap(type)
        attribute_specs[name] = type
        define_method(name) { @attributes[name] }
      end
    end
  end
end

module Types
  class User
    include Plumb::Attributes

    attribute :name, String
    attribute :age, Integer[18..]
  end
end

RSpec.describe Plumb::Attributes do
  specify do
    user = Types::User.new(name: 'Jane', age: 20)
    expect(user.name).to eq 'Jane'
    expect(user.age).to eq 20
    expect(user.valid?).to be true
  end
end

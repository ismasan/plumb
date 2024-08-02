# frozen_string_literal: true

module Plumb
  module Attributes
    # A module that provides a simple way to define a struct-like class with
    # attributes that are type-checked on initialization.
    #
    # @example
    #   class Person
    #     include Plumb::Attributes
    #
    #     attribute :name, Types::String
    #     attribute :age, Types::Integer[18..]
    #   end
    #
    #   person = Person.new(name: 'Jane', age: 20)
    #   person.valid? # => true
    #   person.errors # => {}
    #   person.name # => 'Jane'
    #
    # It supports nested attributes:
    #
    # @example
    #   class Person
    #     include Plumb::Attributes
    #
    #     attribute :friend do
    #       attribute :name, String
    #     end
    #   end
    #
    #   person = Person.new(friend: { name: 'John' })
    #
    # Or arrays of nested attributes:
    #
    # @example
    #   class Person
    #     include Plumb::Attributes
    #
    #     attribute :friends, Types::Array do
    #       atrribute :name, String
    #     end
    #   end
    #
    #   person = Person.new(friends: [{ name: 'John' }])
    #
    # Or use struct classes defined separately:
    #
    # @example
    #   class Company
    #     include Plumb::Attributes
    #     attribute :name, String
    #   end
    #
    #   class Person
    #     include Plumb::Attributes
    #
    #     # Single nested struct
    #     attribute :company, Company
    #
    #     # Array of nested structs
    #     attribute :companies, Types::Array[Company]
    #   end
    #
    # Arrays and other types support composition and helpers. Ex. `#default`.
    #
    #   attribute :companies, Types::Array[Company].default([].freeze)
    #
    # Passing a named struct class AND a block will subclass the struct and extend it with new attributes:
    #
    #   attribute :companby, Company do
    #     attribute :address, String
    #   end
    #
    # The same works with arrays:
    #
    #   attribute :companies, Types::Array[Company] do
    #     attribute :address, String
    #   end
    #
    # Note that this does NOT work with union'd or piped structs.
    #
    #   attribute :company, Company | Person do
    #
    # ## Optional Attributes
    # Using `attribute?` allows for optional attributes. If the attribute is not present, it will be set to `Undefined`.
    #
    #   attribute? :company, Company
    #
    # ## Struct Inheritance
    # Structs can inherit from other structs. This is useful for defining a base struct with common attributes.
    #
    #   class BasePerson
    #     include Plumb::Attributes
    #
    #     attribute :name, String
    #   end
    #
    #   class Person < BasePerson
    #     attribute :age, Integer
    #   end
    #
    # ## [] Syntax
    #
    # The `[]` syntax can be used to define a struct in a single line.
    # Like Plumb::Types::Hash, suffixing a key with `?` makes it optional.
    #
    #   Person = Struct[name: String, age?: Integer]
    #   person = Person.new(name: 'Jane')
    #
    def self.included(base)
      base.send(:extend, ClassMethods)
    end

    attr_reader :errors, :attributes

    def initialize(attrs = {})
      assign_attributes(attrs)
    end

    private def assign_attributes(attrs = BLANK_HASH)
      @errors = {}
      @attributes = self.class.attribute_specs.each_with_object({}) do |(key, type), hash|
        name = key.to_sym
        if attrs.key?(name)
          value = attrs[name]
          result = type.resolve(value)
          @errors[name] = result.errors unless result.valid?
          hash[name] = result.value
        elsif !key.optional?
          result = type.resolve(Undefined)
          @errors[name] = result.errors unless result.valid?
          hash[name] = result.value
        end
      end
    end

    def ==(other)
      other.is_a?(self.class) && other.attributes == attributes
    end

    # @return [Boolean]
    def valid? = errors.none?

    # @param attrs [Hash]
    # @return [Plumb::Attributes]
    def with(attrs = BLANK_HASH)
      self.class.new(attributes.merge(attrs))
    end

    def inspect
      %(#<#{self.class}:#{object_id} [#{valid? ? 'valid' : 'invalid'}] #{attributes.map do |k, v|
                                                                           [k, v.inspect].join(':')
                                                                         end.join(' ')}>)
    end

    # @return [Hash]
    def to_h
      attributes.transform_values do |value|
        case value
        when ::Array
          value.map { |v| v.respond_to?(:to_h) ? v.to_h : v }
        else
          value.respond_to?(:to_h) ? value.to_h : value
        end
      end
    end

    module ClassMethods
      def attribute_specs
        @attribute_specs ||= {}
      end

      def inherited(subclass)
        attribute_specs.each do |key, type|
          subclass.attribute_specs[key] = type
        end
        super
      end

      # The Plumb::Step interface
      # @param result [Plumb::Result::Valid]
      # @return [Plumb::Result::Valid, Plumb::Result::Invalid]
      def call(result)
        return result.invalid(errors: ['Must be a Hash of attributes']) unless result.value.is_a?(Hash)

        instance = new(result.value)
        instance.valid? ? result.valid(instance) : result.invalid(instance, errors: instance.errors)
      end

      # Person = Struct[:name => String, :age => Integer, title?: String]
      def [](type_specs)
        klass = Class.new(self)
        type_specs.each do |key, type|
          klass.attribute(key, type)
        end
        klass
      end

      # attribute(:friend) { attribute(:name, String) }
      # attribute(:friend, MyStruct) { attribute(:name, String) }
      # attribute(:name, String)
      # attribute(:friends, Types::Array) { attribute(:name, String) }
      # attribute(:friends, Types::Array) # same as Types::Array[Types::Any]
      # attribute(:friends, Types::Array[Person])
      #
      def attribute(name, type = Types::Any, &block)
        key = Key.wrap(name)
        name = key.to_sym
        type = Composable.wrap(type)
        if block_given? # :foo, Array[Struct] or :foo, Struct
          type = Composable.wrap(Types::Struct) if type == Types::Any
          type = Plumb.decorate(type) do |node|
            if node.is_a?(Plumb::ArrayClass)
              child = node.children.first
              child = Composable.wrap(Types::Struct) if child == Types::Any
              Types::Array[build_nested(name, child, &block)]
            elsif node.is_a?(Plumb::Step)
              build_nested(name, node, &block)
            elsif node.is_a?(Class) && node <= Plumb::Attributes
              build_nested(name, node, &block)
            else
              node
            end
          end
        end

        attribute_specs[key] = type
        define_method(name) { @attributes[name] }
      end

      def attribute?(name, *args, &block)
        attribute(Key.new(name, optional: true), *args, &block)
      end

      def build_nested(name, node, &block)
        if node.is_a?(Class) && node <= Plumb::Attributes
          sub = Class.new(node)
          sub.instance_exec(&block)
          __set_nested_class__(name, sub)
          return Composable.wrap(sub)
        end

        return node unless node.is_a?(Plumb::Step)

        child = node.children.first
        return node unless child <= Plumb::Attributes

        sub = Class.new(child)
        sub.instance_exec(&block)
        __set_nested_class__(name, sub)
        Composable.wrap(sub)
      end

      def __set_nested_class__(name, klass)
        name = name.to_s.split('_').map(&:capitalize).join.sub(/s$/, '')
        const_set(name, klass) unless const_defined?(name)
      end
    end
  end
end
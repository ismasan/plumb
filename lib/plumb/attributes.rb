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
    #   attribute :company, Company do
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
    #   Person = Data[name: String, age?: Integer]
    #   person = Person.new(name: 'Jane')
    #
    def self.included(base)
      base.send(:extend, ClassMethods)
      base.define_singleton_method(:__plumb_struct_class__) { base }
    end

    attr_reader :errors, :attributes

    def initialize(attrs = {})
      assign_attributes(attrs)
      freeze
    end

    def ==(other)
      other.is_a?(self.class) && other.attributes == attributes
    end

    # @return [Boolean]
    def valid? = !errors || errors.none?

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
      self.class._schema._schema.keys.each.with_object({}) do |key, memo|
        key = key.to_sym
        value = attributes[key]
        val = case value
              when ::Array
                value.map { |v| v.respond_to?(:to_h) ? v.to_h : v }
              when ::NilClass
                nil
              else
                value.respond_to?(:to_h) ? value.to_h : value
              end
        memo[key] = val
      end
    end

    def to_hash = to_h

    def deconstruct(...) = to_h.values.deconstruct(...)
    def deconstruct_keys(...) = to_h.deconstruct_keys(...)

    private

    def assign_attributes(attrs = BLANK_HASH)
      raise ArgumentError, 'Must be a Hash of attributes' unless attrs.respond_to?(:to_h)

      @errors = {}
      result = self.class._schema.resolve(attrs.to_h)
      @attributes = prepare_attributes(result.value)
      @errors = result.errors unless result.valid?
    end

    def prepare_attributes(attrs) = attrs

    module ClassMethods
      def _schema
        @_schema ||= HashClass.new
      end

      def inherited(subclass)
        _schema._schema.each do |key, type|
          subclass.attribute(key, type)
        end
        super
      end

      # The Plumb::Step interface
      # @param result [Plumb::Result::Valid]
      # @return [Plumb::Result::Valid, Plumb::Result::Invalid]
      def call(result)
        return result if result.value.is_a?(self)
        return result.invalid(errors: ['Must be a Hash of attributes']) unless result.value.respond_to?(:to_h)

        instance = new(result.value.to_h)
        instance.valid? ? result.valid(instance) : result.invalid(instance, errors: instance.errors.to_h)
      end

      # Person = Data[:name => String, :age => Integer, title?: String]
      def [](type_specs)
        type_specs = type_specs._schema if type_specs.is_a?(Plumb::HashClass)
        klass = Class.new(self)
        type_specs.each do |key, type|
          klass.attribute(key, type)
        end
        klass
      end

      # node name for visitors
      def node_name = :data

      # attribute(:friend) { attribute(:name, String) }
      # attribute(:friend, MyStruct) { attribute(:name, String) }
      # attribute(:name, String)
      # attribute(:friends, Types::Array) { attribute(:name, String) }
      # attribute(:friends, Types::Array) # same as Types::Array[Types::Any]
      # attribute(:friends, []) # same as Types::Array[Types::Any]
      # attribute(:friends, Types::Array[Person])
      # attribute(:friends, [Person])
      #
      def attribute(name, type = Types::Any, writer: false, &block)
        key = Key.wrap(name)
        name = key.to_sym
        type = Composable.wrap(type)

        if block_given? # :foo, Array[Data] or :foo, Struct
          type = __plumb_struct_class__ if type == Types::Any
          type = Plumb.decorate(type) do |node|
            if node.is_a?(Plumb::ArrayClass)
              child = node.children.first
              child = __plumb_struct_class__ if child == Types::Any
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

        @_schema = _schema + { key => type }
        __plumb_define_attribute_reader_method__(name)
        return name unless writer

        __plumb_define_attribute_writer_method__(name)
      end

      def __plumb_define_attribute_reader_method__(name)
        define_method(name) { @attributes[name] }
      end

      def __plumb_define_attribute_writer_method__(name)
        define_method("#{name}=") do |value|
          type = self.class._schema.at_key(name)
          result = type.resolve(value)
          @attributes[name] = result.value
          if result.valid?
            @errors.delete(name)
          else
            @errors.merge!(name => result.errors)
          end
          result.value
        end
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

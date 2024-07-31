# frozen_string_literal: true

module Plumb
  class Struct
    attr_reader :errors, :attributes

    def initialize(attrs = {})
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

    def self.[](type_specs)
      klass = Class.new(self)
      type_specs.each do |key, type|
        klass.attribute(key, type)
      end
      klass
    end

    def valid? = errors.none?

    def with(attrs = BLANK_HASH)
      self.class.new(attributes.merge(attrs))
    end

    def inspect
      %(#<#{self.class}:#{object_id} [#{valid? ? 'valid' : 'invalid'}] #{attributes.map do |k, v|
                                                                           [k, v.inspect].join(':')
                                                                         end.join(' ')}>)
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

      def inherited(subclass)
        attribute_specs.each do |key, type|
          subclass.attribute_specs[key] = type
        end
        super
      end

      def build_nested(name, node, &block)
        return node unless node.is_a?(Plumb::Step)

        child = node.children.first
        return node unless child <= Plumb::Struct

        sub = Class.new(child)
        sub.instance_exec(&block)
        __set_nested_class__(name, sub)
        Composable.wrap(sub)
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
        name = name.to_sym
        type = Composable.wrap(type)
        if block_given? # :foo, Array[Struct] or :foo, Struct
          type = Composable.wrap(Plumb::Struct) if type == Types::Any
          type = Plumb.decorate(type) do |node|
            if node.is_a?(Plumb::ArrayClass)
              child = node.children.first
              child = Composable.wrap(Plumb::Struct) if child == Types::Any
              Types::Array[build_nested(name, child, &block)]
            elsif node.is_a?(Plumb::Step)
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

      def __set_nested_class__(name, klass)
        name = name.to_s.split('_').map(&:capitalize).join.sub(/s$/, '')
        const_set(name, klass) unless const_defined?(name)
      end
    end
  end
end

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

      # attribute(:friend) { attribute(:name, String) }
      # attribute(:friend, MyStruct) { attribute(:name, String) }
      # attribute(:name, String)
      # attribute(:friends, Types::Array) { attribute(:name, String) }
      # attribute(:friends, Types::Array) # same as Types::Array[Types::Any]
      # attribute(:friends, Types::Array[Person])
      #
      def attribute(name, *args, &block)
        key = Key.wrap(name)
        name = name.to_sym

        type = case args
               in [Class => klass] if block_given? # attribute(:friend, MyStruct) { ... }
                 sub = Class.new(klass)
                 sub.instance_exec(&block)
                 __set_nested_class__(name, sub)
                 Plumb::Composable.wrap(sub)
               in [] if block_given? # attribute(:friend) { ... }
                 sub = Class.new(Plumb::Struct)
                 sub.instance_exec(&block)
                 __set_nested_class__(name, sub)
                 Plumb::Composable.wrap(sub)
               in [Plumb::ArrayClass => type]
                 sub = type.element_type
                 if sub == Plumb::Types::Any
                   if block_given?
                     sub = Class.new(Plumb::Struct)
                     sub.instance_exec(&block)
                     __set_nested_class__(name, sub)
                     Plumb::Types::Array[Plumb::Composable.wrap(sub)]
                   else
                     type
                   end
                 else
                   type
                 end
               in [Plumb::Composable => type] # attribute(:name, String)
                 type
               in [type]
                 Plumb::Composable.wrap(type)
               else
                 raise ArgumentError, "Invalid arguments: #{args.inspect}"
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

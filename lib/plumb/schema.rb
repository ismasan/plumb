# frozen_string_literal: true

require 'forwardable'
require 'plumb/json_schema_visitor'

module Plumb
  class Schema
    include Composable

    def self.wrap(sch = nil, &block)
      raise ArgumentError, 'expected a block or a schema' if sch.nil? && !block_given?

      if sch
        raise ArgumentError, 'expected a Composable' unless sch.is_a?(Composable)

        return sch
      end

      new(&block)
    end

    attr_reader :fields

    def initialize(hash = Types::Hash, &block)
      @pipeline = Types::Any
      @before = Types::Any
      @after = Types::Any
      @_hash = hash
      @fields = @_hash._schema.each.with_object(SymbolAccessHash.new({})) do |(k, v), memo|
        memo[k] = Field.new(k, v)
      end

      setup(&block) if block_given?

      finish
    end

    def inspect
      "#{self.class}#{fields.keys.inspect}"
    end

    def before(callable = nil, &block)
      @before >>= callable || block
      self
    end

    def after(callable = nil, &block)
      @after >>= callable || block
      self
    end

    def to_json_schema
      _hash.to_json_schema(root: true)
    end

    def call(result)
      @pipeline.call(result)
    end

    private def setup(&block)
      case block.arity
      when 1
        yield self
      when 0
        instance_eval(&block)
      else
        raise ::ArgumentError, "#{self.class} expects a block with 0 or 1 argument, but got #{block.arity}"
      end
      @_hash = Types::Hash.schema(@fields.transform_values(&:_type))
      self
    end

    private def finish
      @pipeline = @before.freeze >> @_hash.freeze >> @after.freeze
      freeze
    end

    def field(key, type = nil, &block)
      key = Key.new(key.to_sym)
      @fields[key] = Field.new(key, type, &block)
    end

    def field?(key, type = nil, &block)
      key = Key.new(key.to_sym, optional: true)
      @fields[key] = Field.new(key, type, &block)
    end

    def +(other)
      self.class.new(_hash + other._hash)
    end

    def &(other)
      self.class.new(_hash & other._hash)
    end

    def merge(other = nil, &block)
      other = self.class.wrap(other, &block)
      self + other
    end

    protected

    attr_reader :_hash

    class SymbolAccessHash < SimpleDelegator
      def [](key)
        __getobj__[Key.wrap(key)]
      end
    end

    class Field
      include Callable

      attr_reader :_type, :key

      def initialize(key, type = nil, &block)
        @key = key.to_sym
        @_type = case type
                 when ArrayClass, Array
                   block_given? ? ArrayClass.new(element_type: Schema.new(&block)) : type
                 when nil
                   block_given? ? Schema.new(&block) : Types::Any
                 when Composable
                   type
                 when Class
                   if type == Array && block_given?
                     ArrayClass.new(element_type: Schema.new(&block))
                   else
                     Types::Any[type]
                   end
                 else
                   raise ArgumentError, "expected a Plumb type, but got #{type.inspect}"
                 end
      end

      def call(result) = _type.call(result)

      def default(v, &block)
        @_type = @_type.default(v, &block)
        self
      end

      def metadata(data = Undefined)
        if data == Undefined
          @_type.metadata
        else
          @_type = @_type.metadata(data)
        end
      end

      def options(opts)
        @_type = @_type.options(opts)
        self
      end

      def nullable
        @_type = @_type.nullable
        self
      end

      def present
        @_type = @_type.present
        self
      end

      def required
        @_type = Types::Undefined.invalid(errors: 'is required') >> @_type
        self
      end

      def match(matcher)
        @_type = @_type.match(matcher)
        self
      end

      def policy(...)
        @_type = @_type.policy(...)
        self
      end

      def inspect
        "#{self.class}[#{@_type.inspect}]"
      end

      private

      attr_reader :registry
    end
  end
end

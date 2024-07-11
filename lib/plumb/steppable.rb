# frozen_string_literal: true

require 'plumb/metadata_visitor'

module Plumb
  class UndefinedClass
    def inspect
      %(Undefined)
    end

    def to_s = inspect
    def node_name = :undefined
  end

  TypeError = Class.new(::TypeError)
  Undefined = UndefinedClass.new.freeze

  BLANK_STRING = ''
  BLANK_ARRAY = [].freeze
  BLANK_HASH = {}.freeze
  BLANK_RESULT = Result.wrap(Undefined)
  NOOP = ->(result) { result }

  module Callable
    def metadata
      MetadataVisitor.call(self)
    end

    def resolve(value = Undefined)
      call(Result.wrap(value))
    end

    def parse(value = Undefined)
      result = resolve(value)
      raise TypeError, result.errors if result.invalid?

      result.value
    end

    def call(result)
      raise NotImplementedError, "Implement #call(Result) => Result in #{self.class}"
    end
  end

  module Steppable
    include Callable

    def self.included(base)
      nname = base.name.split('::').last
      nname.gsub!(/([a-z\d])([A-Z])/, '\1_\2')
      nname.downcase!
      nname.gsub!(/_class$/, '')
      nname = nname.to_sym
      base.define_method(:node_name) { nname }
    end

    def self.wrap(callable)
      if callable.is_a?(Steppable)
        callable
      elsif callable.is_a?(::Hash)
        HashClass.new(schema: callable)
      elsif callable.respond_to?(:call)
        Step.new(callable)
      else
        MatchClass.new(callable)
      end
    end

    attr_reader :name

    class Name
      def initialize(name)
        @name = name
      end

      def to_s = @name

      def set(n)
        @name = n
        self
      end
    end

    def freeze
      return self if frozen?

      @name = Name.new(_inspect)
      super
    end

    private def _inspect = self.class.name

    def inspect = name.to_s

    def node_name = self.class.name.split('::').last.to_sym

    def defer(definition = nil, &block)
      Deferred.new(definition || block)
    end

    def >>(other)
      And.new(self, Steppable.wrap(other))
    end

    def |(other)
      Or.new(self, Steppable.wrap(other))
    end

    def transform(target_type, callable = nil, &block)
      self >> Transform.new(target_type, callable || block)
    end

    def check(errors = 'did not pass the check', &block)
      self >> MatchClass.new(block, error: errors)
    end

    def meta(data = {})
      self >> Metadata.new(data)
    end

    def not(other = self)
      Not.new(other)
    end

    def invalid(errors: nil)
      Not.new(self, errors:)
    end

    def value(val)
      self >> ValueClass.new(val)
    end

    def match(*args)
      self >> MatchClass.new(*args)
    end

    def [](val) = match(val)

    DefaultProc = proc do |callable|
      proc do |result|
        result.valid(callable.call)
      end
    end

    def default(val = Undefined, &block)
      val_type = if val == Undefined
                   DefaultProc.call(block)
                 else
                   Types::Static[val]
                 end

      self | (Types::Undefined >> val_type)
    end

    class Node
      include Steppable

      attr_reader :node_name, :type, :attributes

      def initialize(node_name, type, attributes = BLANK_HASH)
        @node_name = node_name
        @type = type
        @attributes = attributes
        freeze
      end

      def call(result) = type.call(result)
    end

    def as_node(node_name, metadata = BLANK_HASH)
      Node.new(node_name, self, metadata)
    end

    def nullable
      Types::Nil | self
    end

    def present
      Types::Present >> self
    end

    def options(opts = [])
      rule(included_in: opts)
    end

    def rule(*args)
      specs = case args
              in [::Symbol => rule_name, value]
                { rule_name => value }
              in [::Hash => rules]
                rules
              else
                raise ArgumentError, "expected 1 or 2 arguments, but got #{args.size}"
              end

      self >> Rules.new(specs, metadata[:type])
    end

    def ===(other)
      case other
      when Steppable
        other == self
      else
        resolve(other).valid?
      end
    end

    def build(cns, factory_method = :new, &block)
      self >> Build.new(cns, factory_method:, &block)
    end

    def pipeline(&block)
      Pipeline.new(self, &block)
    end

    def to_s
      inspect
    end

    # @param method_name [Symbol] method to invoke on the value
    # @param args [Array] arguments to pass to the method, if any
    # @yield block
    # @return [Step]
    def invoke(method_name, *args, &block)
      types = Array(metadata[:type]).uniq
      unless types.size == 1 && types.first.is_a?(Class) && types.first.instance_methods.include?(method_name)
        raise NoMethodError, "#{types.first.inspect} does not respond to `#{method_name}'"
      end

      self >> Step.new(
        ->(result) { result.valid(result.value.public_send(method_name, *args, &block)) },
        [method_name.inspect, args.inspect].join(' ')
      )
    end
  end
end

require 'plumb/deferred'
require 'plumb/transform'
require 'plumb/build'
require 'plumb/metadata'

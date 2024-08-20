# frozen_string_literal: true

require 'plumb/metadata_visitor'

module Plumb
  class UndefinedClass
    def inspect
      %(Undefined)
    end

    def to_s = inspect
    def node_name = :undefined
    def empty? = true
  end

  ParseError = Class.new(::TypeError)
  Undefined = UndefinedClass.new.freeze

  BLANK_STRING = ''
  BLANK_ARRAY = [].freeze
  BLANK_HASH = {}.freeze
  BLANK_RESULT = Result.wrap(Undefined)
  NOOP = ->(result) { result }

  module Callable
    def resolve(value = Undefined)
      call(Result.wrap(value))
    end

    def parse(value = Undefined)
      result = resolve(value)
      raise ParseError, result.errors if result.invalid?

      result.value
    end

    def call(result)
      raise NotImplementedError, "Implement #call(Result) => Result in #{self.class}"
    end
  end

  # This module gets included by Composable,
  # but only when Composable is `included` in classes, not `extended`.
  # The rule of this module is to assign a name to constants that point to Composable instances.
  module Naming
    attr_reader :name

    # When including this module,
    # define a #node_name method on the Composable instance
    # #node_name is used by Visitors to determine the type of node.
    def self.included(base)
      nname = base.name.split('::').last
      nname.gsub!(/([a-z\d])([A-Z])/, '\1_\2')
      nname.downcase!
      nname.gsub!(/_class$/, '')
      nname = nname.to_sym
      base.define_method(:node_name) { nname }
    end

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
  end

  #  Composable mixes in composition methods to classes.
  # such as #>>, #|, #not, and others.
  # Any Composable class can participate in Plumb compositions.
  module Composable
    include Callable

    # This only runs when including Composable,
    # not extending classes with it.
    def self.included(base)
      base.send(:include, Naming)
    end

    def self.wrap(callable)
      if callable.is_a?(Composable)
        callable
      elsif callable.is_a?(::Hash)
        HashClass.new(schema: callable)
      elsif callable.respond_to?(:call)
        Step.new(callable)
      else
        MatchClass.new(callable)
      end
    end

    def defer(definition = nil, &block)
      Deferred.new(definition || block)
    end

    def >>(other)
      And.new(self, Composable.wrap(other))
    end

    def |(other)
      Or.new(self, Composable.wrap(other))
    end

    def transform(target_type, callable = nil, &block)
      self >> Transform.new(target_type, callable || block)
    end

    def check(errors = 'did not pass the check', &block)
      self >> MatchClass.new(block, error: errors, label: errors)
    end

    def metadata(data = Undefined)
      if data == Undefined
        MetadataVisitor.call(self)
      else
        self >> Metadata.new(data)
      end
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

    class Node
      include Composable

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

    # Register a policy for this step.
    # Mode 1.a: #policy(:name, arg) a single policy with an argument
    # Mode 1.b: #policy(:name) a single policy without an argument
    # Mode 2: #policy(p1: value, p2: value) multiple policies with arguments
    # The latter mode will be expanded to multiple #policy calls.
    # @return [Step]
    def policy(*args, &blk)
      case args
      in [::Symbol => name, *rest] # #policy(:name, arg)
        types = Array(metadata[:type]).uniq

        bargs = [self]
        arg = Undefined
        if rest.any?
          bargs << rest.first
          arg = rest.first
        end
        block = Plumb.policies.get(types, name)
        pol = block.call(*bargs, &blk)

        Policy.new(name, arg, pol)
      in [::Hash => opts] # #policy(p1: value, p2: value)
        opts.reduce(self) { |step, (name, value)| step.policy(name, value) }
      else
        raise ArgumentError, "expected a symbol or hash, got #{args.inspect}"
      end
    end

    def ===(other)
      case other
      when Composable
        other == self
      else
        resolve(other).valid?
      end
    end

    def ==(other)
      other.is_a?(self.class) && other.children == children
    end

    def children = BLANK_ARRAY

    def build(cns, factory_method = :new, &block)
      self >> Build.new(cns, factory_method:, &block)
    end

    def pipeline(&block)
      Pipeline.new(self, &block)
    end

    def to_s
      inspect
    end

    # @option root [Boolean] whether to include JSON Schema $schema property
    # @return [Hash]
    def to_json_schema(root: false)
      JSONSchemaVisitor.call(self, root:)
    end

    # Build a step that will invoke one or more methods on the value.
    # Ex 1: Types::String.invoke(:downcase)
    # Ex 2: Types::Array.invoke(:[], 1)
    # Ex 3 chain of methods: Types::String.invoke([:downcase, :to_sym])
    # @return [Step]
    def invoke(*args, &block)
      case args
      in [::Symbol => method_name, *rest]
        self >> Step.new(
          ->(result) { result.valid(result.value.public_send(method_name, *rest, &block)) },
          [method_name.inspect, rest.inspect].join(' ')
        )
      in [Array => methods] if methods.all? { |m| m.is_a?(Symbol) }
        methods.reduce(self) { |step, method| step.invoke(method) }
      else
        raise ArgumentError, "expected a symbol or array of symbols, got #{args.inspect}"
      end
    end
  end
end

require 'plumb/deferred'
require 'plumb/transform'
require 'plumb/policy'
require 'plumb/build'
require 'plumb/metadata'

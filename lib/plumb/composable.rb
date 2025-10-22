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

  # Override #=== and #== for Composable instances.
  # but only when included in classes, not extended.
  module Equality
    # `#===` equality. So that Plumb steps can be used in case statements and pattern matching.
    # @param other [Object]
    # @return [Boolean]
    def ===(other)
      case other
      when Composable
        other == self
      else
        resolve(other).valid?
      end
    end

    def ==(other)
      other.is_a?(self.class) && other.respond_to?(:children) && other.children == children
    end
  end

  #  Composable mixes in composition methods to classes.
  # such as #>>, #|, #not, and others.
  # Any Composable class can participate in Plumb compositions.
  # A host object only needs to implement the Step interface `call(Result::Valid) => Result::Valid | Result::Invalid`
  module Composable
    include Callable

    # This only runs when including Composable,
    # not extending classes with it.
    def self.included(base)
      base.send(:include, Naming)
      base.send(:include, Equality)
    end

    # Wrap an object in a Composable instance.
    # Anything that includes Composable is a noop.
    # A Hash is assumed to be a HashClass schema.
    # An Array with zero or 1 element is assumed to be an ArrayClass.
    # Any `#call(Result) => Result` interface is wrapped in a Step.
    # Anything else is assumed to be something you want to match against via `#===`.
    #
    # @example
    #   ten = Composable.wrap(10)
    #   ten.resolve(10) # => Result::Valid
    #   ten.resolve(11) # => Result::Invalid
    #
    # @param callable [Object]
    # @return [Composable]
    def self.wrap(callable)
      if callable.is_a?(Composable)
        callable
      elsif callable.is_a?(::Hash)
        HashClass.new(schema: callable)
      elsif callable.is_a?(::Array)
        element_type = case callable.size
                       when 0
                         Types::Any
                       when 1
                         callable.first
                       else
                         raise ArgumentError, '[element_type] syntax allows a single element type'
                       end
        Types::Array[element_type]
      elsif callable.respond_to?(:call)
        Step.new(callable)
      else
        MatchClass.new(callable)
      end
    end

    # A helper to wrap a block in a Step that will defer execution.
    # This so that types can be used recursively in compositions.
    # @example
    #   LinkedList = Types::Hash[
    #     value: Types::Any,
    #     next: Types::Any.defer { LinkedList }
    #   ]
    def defer(definition = nil, &block)
      Deferred.new(definition || block)
    end

    # Chain two composable objects together.
    # A.K.A "and" or "sequence"
    # @example
    #   Step1 >> Step2 >> Step3
    #
    # @param other [Composable]
    # @return [And]
    def >>(other)
      And.new(self, Composable.wrap(other))
    end

    # Chain two composable objects together as a disjunction ("or").
    #
    # @param other [Composable]
    # @return [Or]
    def |(other)
      Or.new(self, Composable.wrap(other))
    end

    # Transform value. Requires specifying the resulting type of the value after transformation.
    # @example
    #   Types::String.transform(Types::Symbol, &:to_sym)
    #
    # @param target_type [Class] what type this step will transform the value to
    # @param callable [#call, nil] a callable that will be applied to the value, or nil if block provided
    # @param block [Proc] a block that will be applied to the value, or nil if callable provided
    # @return [And]
    def transform(target_type, callable = nil, &block)
      self >> Transform.new(target_type, callable || block)
    end

    # Pass the value through an arbitrary validation
    # @example
    #   type = Types::String.check('must start with "Role:"') { |value| value.start_with?('Role:') }
    #
    # @param errors [String] error message to use when validation fails
    # @param block [Proc] a block that will be applied to the value
    # @return [And]
    def check(errors = 'did not pass the check', &block)
      self >> MatchClass.new(block, error: errors, label: errors)
    end

    # Return a new Step with added metadata, or build step metadata if no argument is provided.
    # @example
    #   type = Types::String.metadata(label: 'Name')
    #   type.metadata # => { type: String, label: 'Name' }
    #
    # @param data [Hash] metadata to add to the step
    # @return [Hash, And]
    def metadata(data = Undefined)
      if data == Undefined
        MetadataVisitor.call(self)
      else
        Metadata.new(self, data)
      end
    end

    # Negate the result of a step.
    # Ie. if the step is valid, it will be invalid, and vice versa.
    # @example
    #   type = Types::String.not
    #   type.resolve('foo') # invalid
    #   type.resolve(10) # valid
    #
    # @return [Not]
    def not(other = self)
      Not.new(other)
    end

    # Like #not, but with a custom error message.
    #
    # @option errors [String] error message to use when validation fails
    # @return [Not]
    def invalid(errors: nil)
      Not.new(self, errors:)
    end

    #  Match a value using `#==`
    # Normally you'll build matchers via ``#[]`, which uses `#===`.
    # Use this if you want to match against concrete instances of things that respond to `#===`
    # @example
    #   regex = Types::Any.value(/foo/)
    #   regex.resolve('foo') # invalid. We're matching against the regex itself.
    #   regex.resolve(/foo/) # valid
    #
    # @param value [Object]
    # @rerurn [And]
    def value(val)
      self >> ValueClass.new(val)
    end

    # Alias of `#[]`
    # Match a value using `#===`
    # @example
    #   email = Types::String['@']
    #
    # @param args [Array<Object>]
    # @return [And]
    def match(*args)
      self >> MatchClass.new(*args)
    end

    def [](val) = match(val)

    #  Support #as_node.
    class Node
      include Composable

      attr_reader :node_name, :type, :args

      def initialize(node_name, type, args = BLANK_HASH)
        @node_name = node_name
        @type = type
        @args = args
        freeze
      end

      # When wrapping a node in Metadata
      # we need to preserte the Node with cistom node_name.
      # but when just querying metadata,
      # we can delegate to the underlying type.
      def metadata(data = Undefined)
        if data == Undefined
          type.metadata
        else
          Metadata.new(self, data)
        end
      end

      def call(result) = type.call(result)
    end

    #  Wrap a Step in a node with a custom #node_name
    # which is expected by visitors.
    # So that we can define special visitors for certain compositions.
    # Ex. Types::Boolean is a compoition of Types::True | Types::False, but we want to treat it as a single node.
    #
    # @param node_name [Symbol]
    # @param args [Hash]
    # @return [Node]
    def as_node(node_name, args = BLANK_HASH)
      Node.new(node_name, self, args)
    end

    # Check attributes of an object against values, using #===
    # @example
    #   type = Types::Array.where(size: 1..10)
    #   type = Types::String.where(bytesize: 1..10)
    #
    # @param attrs [Hash]
    def where(attrs)
      attrs.reduce(self) do |t, (name, value)|
        t >> AttributeValueMatch.new(t, name, value)
      end
    end

    # @deprecated User {#where} instead
    def with(...)
      warn 'Composable#with() is deprecated. Use #where() instead. #with is reserved to make copies of Data structs'
      where(...)
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
        if rest.size.positive?
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

    # Visitors expect a #node_name and #children interface.
    # @return [Array<Composable>]
    def children = BLANK_ARRAY

    # Compose a step that instantiates a class.
    # @example
    #   type = Types::String.build(MyClass, :new)
    #   thing = type.parse('foo') # same as MyClass.new('foo')
    #
    # It sets the class as the output type of the step.
    # Optionally takes a block.
    #
    #   type = Types::String.build(Money) { |value| Monetize.parse(value) }
    #
    # @param cns [Class] constructor class or object.
    # @param factory_method [Symbol] method to call on the class to instantiate it.
    # @return [And]
    def build(cns, factory_method = :new, &block)
      self >> Build.new(cns, factory_method:, &block)
    end

    # Always return a static value, regardless of the input.
    # @example
    #   type = Types::Integer.static(10)
    #   type.parse(10) # => 10
    #   type.parse(100) # => 10
    #   type.parse # => 10
    #
    # @param value [Object]
    # @return [And]
    def static(value)
      my_type = Array(metadata[:type]).first
      unless my_type.nil? || value.instance_of?(my_type)
        raise ArgumentError,
              "can't set a static #{value.class} value for a #{my_type} step"
      end

      StaticClass.new(value) >> self
    end

    # Return the output of a block or #call interface, regardless of input.
    # The block will be called to get the value, on every invocation.
    # @example
    #  now = Types::Integer.generate { Time.now.to_i }
    #
    # @param generator [#call, nil] a callable that will be applied to the value, or nil if block
    # @param block [Proc] a block that will be applied to the value, or nil if callable
    # @return [And]
    def generate(generator = nil, &block)
      generator ||= block
      raise ArgumentError, 'expected a generator' unless generator.respond_to?(:call)

      Step.new(->(r) { r.valid(generator.call) }, 'generator') >> self
    end

    # Build a Plumb::Pipeline with this object as the starting step.
    # @example
    #   pipe = Types::Data[name: String].pipeline do |pl|
    #     pl.step Validate
    #     pl.step Debug
    #     pl.step Log
    # end
    #
    # @return [Pipeline]
    def pipeline(&block)
      Pipeline.new(type: self, &block)
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
require 'plumb/attribute_value_match'
require 'plumb/transform'
require 'plumb/policy'
require 'plumb/build'
require 'plumb/metadata'

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
  # Raised by Composable#>> when chaining two steps whose types are provably
  # incompatible (the left's #output_type is not a subtype of the right's
  # #input_type).
  TypeError = Class.new(::TypeError)
  Undefined = UndefinedClass.new.freeze

  BLANK_STRING = ''
  BLANK_ARRAY = [].freeze
  BLANK_HASH = {}.freeze
  NOOP = ->(result) { result }

  # Ruby's explicit conversion methods and the type each produces. Lets
  # `#transform(:to_i)` expand to a typed transform to Integer (using `:to_i` as
  # the callable), instead of spelling out `#transform(Integer, &:to_i)`.
  COERCION_METHODS = {
    to_s: ::String,
    to_sym: ::Symbol,
    to_i: ::Integer,
    to_f: ::Float,
    to_r: ::Rational,
    to_c: ::Complex,
    to_a: ::Array,
    to_h: ::Hash,
    to_proc: ::Proc
  }.freeze

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

    # Subtype/subset operator. `a <= b` is true when every value described by
    # `self` is also described by `other` (`other` may be a raw Ruby class or
    # value; it is normalized). Delegates to the generic Plumb::Subtyping engine.
    # @param other [Composable, Class, Object]
    # @return [Boolean]
    def <=(other)
      Plumb::Subtyping.subtype?(self, other)
    end

    # `self` is a supertype of `other`: every value of `other` is a value of
    # `self`.
    def >=(other)
      Plumb::Subtyping.subtype?(Composable.wrap(other), self)
    end

    # Strict subtype / supertype.
    def <(other) = (self <= other) && !(self >= other)
    def >(other) = (self >= other) && !(self <= other)

    # Leaf hook for Plumb::Subtyping.subtype?, called once the algebra (And/Or/
    # Transform/top) has been peeled away. It must NOT delegate back to #<= (that
    # would recurse); it recurses only through Plumb::Subtyping.subtype?.
    #
    # Default behaviour:
    #   1. reflexive structural equality;
    #   2. atomic leaves (a single raw matcher/value) compared via Ruby
    #      semantics (Plumb::Subtyping.atomic_subtype?);
    #   3. covariant containers — same class with pairwise-subtype children,
    #      which covers Array/Tuple/HashMap/Stream and any custom container that
    #      exposes #children, for free.
    #
    # Override for bespoke leaf relations (see HashClass width/depth subtyping).
    # @param other [Composable]
    # @return [Boolean]
    def subtype_of?(other)
      return true if self == other

      if Plumb::Subtyping.atomic?(self) && Plumb::Subtyping.atomic?(other)
        return Plumb::Subtyping.atomic_subtype?(children.first, other.children.first)
      end

      return false unless other.instance_of?(self.class)
      return false if children.empty? || children.size != other.children.size

      children.zip(other.children).all? { |c, o| Plumb::Subtyping.subtype?(c, o) }
    end

    # Mirror of #subtype_of?, for relations the *supertype* owns and the subtype
    # can't know about (eg. Interface duck-typing: any type is a subtype of an
    # Interface whose methods its values support). Consulted by
    # Plumb::Subtyping.subtype? only after #subtype_of? declines. Default: no —
    # only the subtype side decides. Recurse via Plumb::Subtyping.subtype?, never
    # #<=. Override for bespoke supertype behaviour (see InterfaceClass).
    # @param other [Composable]
    # @return [Boolean]
    def supertype_of?(other) = false
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
        Constraint.new(callable)
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

    def input_type = self
    def output_type = self

    # The type that carries this node's identity for the subtype relation. A
    # value-preserving type IS its own identity (the default). A value-converting
    # type is identified by what it *produces*, so it projects onto a DISTINCT
    # type (see Transform#subtype_identity => output_type): Plumb::Subtyping.subtype?
    # reduces `a <= b` to `produced(a) <= b` before consulting the leaf hooks.
    #
    # CONTRACT: only return a value other than `self` when that value is a
    # genuinely different node. Returning `self` here is a no-op (subtype? guards
    # with `!equal?(self)`, so it simply won't reduce); returning a node whose own
    # #subtype_identity loops back would recurse forever. This is the extension
    # point for building custom transforming types that play well with subtyping
    # WITHOUT subclassing Transform.
    def subtype_identity = self

    # The type this step accepts as the consumer of a `left >> self` chain — the
    # values its #call processes without rejecting outright. Defaults to what it
    # takes as input (its resolved #input_type): right for plain matchers and for
    # conversion/consumer types (Transform, Stream, Pipeline — they accept their
    # declared input, so they need no override). Two kinds of type override it:
    #   - a refinement (And): its #input_type is only the base (left) type and
    #     would drop the constraint it adds, so it accepts its resolved *output*;
    #   - a Hash: it relaxes each field to what that field accepts.
    # Consulted by Plumb::Subtyping when checking `#>>`.
    def accepted_type = Plumb::Subtyping.resolved_input(self)

    # Whether running this step twice in a row is the same as running it once,
    # i.e. it validates without changing the value. Lets `#>>` drop a redundant
    # `X >> X`. Default false; only types that never transform the value opt in
    # (see Constraint). A transform must NOT be idempotent — `X >> X` would
    # apply it twice.
    def idempotent? = false

    # Whether this type returns its input value UNCHANGED on success — a
    # coreflexive refinement (a pure filter). Lets `#|` absorb a redundant
    # branch (`Integer | Numeric == Numeric`) without dropping a coercion. See
    # Subtyping.reduce_union, which memoizes this per frozen node in TypeCache.
    # Default false; refinements opt in, transforms stay false. A covariant
    # container (Array/Tuple/HashMap) preserves the value exactly when all its
    # element/child types do — so `Array[Integer] >> Array[Numeric]` collapses
    # like the scalar `Integer >> Numeric` — while a container that reshapes the
    # value (a filtered map dropping entries, a record dropping undeclared keys)
    # stays false. A stronger property than #idempotent? (value-preserving ⟹
    # idempotent).
    def value_preserving? = false

    # Chain two composable objects together.
    # A.K.A "and" or "sequence"
    # @example
    #   Step1 >> Step2 >> Step3
    #
    # Type-checks the composition by subsumption: everything `self` produces
    # must be acceptable to `other` (`self`'s output a subtype of `other`'s
    # input), else it raises Plumb::TypeError — eg. `String >> Integer`, or
    # `Integer[0..40] >> Integer[2..10]` (the left can emit values the right
    # rejects). To narrow a value, use `#[]` / `#transform(...)[...]` (a
    # refinement is a runtime-checked cast, built directly and not subtype-
    # checked). The check is permissive only where types are unknown: opaque
    # steps (plain procs, transforms, narrowing matchers) report Any and opt out.
    #
    # @param other [Composable]
    # @raise [Plumb::TypeError] when `self`'s output is not a subtype of `other`'s input.
    # @return [And]
    def >>(other)
      other = Composable.wrap(other)
      # `X >> X` is redundant for a value-preserving validator (eg. Types::String):
      # validating the same value twice is the same as once. Gated on #idempotent?
      # so transforms — where `X >> X` would apply the change twice — never collapse.
      return self if idempotent? && self == other

      Plumb::Subtyping.check_composable!(self, other)
      # Drop what `other` re-asserts that `self` already guarantees. reduce_step
      # folds a base-type gate into a Constraint chain (`Integer[0..100] >>
      # Integer[-10..110]` -> `Integer[0..100]`, `::Integer` validated once);
      # redundant_refinement? does the same for any value-preserving `other` that
      # `self` already subsumes (`String.where(size: 3..10) >> .where(size: 0..)`
      # -> the former). A non-redundant `other` (a transform, or a narrowing
      # refinement) stays an And.
      Plumb::Subtyping.reduce_step(self, other) ||
        (Plumb::Subtyping.redundant_refinement?(self, other) ? self : And.new(self, other))
    end

    # Compose like #>> but WITHOUT the strict subtype check — the escape hatch
    # for chains the checker can't prove safe but you know are (eg. a narrowing
    # like `Types::Integer / Types::Integer[1..10]`, or feeding a producer whose
    # output you know the right side accepts). You assert the composition is
    # valid; it is still runtime-checked when data flows through. Reduces and
    # builds the same refinement as #>> (just skipping the build-time check), so
    # the result participates in subtyping like any other refinement. The `/` reads as
    # `Pathname#/` does — "join the next segment". When `self` is the Any top the
    # right side stands alone, consistent with #[].
    #
    # @param other [Composable]
    # @return [Composable]
    def /(other)
      constrain(Composable.wrap(other))
    end

    # Chain two composable objects together as a disjunction ("or").
    # When one value-preserving branch subsumes the other (`Integer | Numeric`,
    # or `X | X`), the union absorbs to the wider branch — see
    # Subtyping.reduce_union. Transforms/containers never reduce (they may accept
    # inputs the survivor rejects), so coercion unions are preserved.
    #
    # @param other [Composable]
    # @return [Composable]
    def |(other)
      other = Composable.wrap(other)
      return self if other.is_a?(NeverClass) # X | Never == X

      Plumb::Subtyping.reduce_union(self, other) ||
        Plumb::Subtyping.factor_union(self, other) ||
        Or.new(self, other)
    end

    # Intersection ("and"/meet) — the symmetric dual of #|. Builds the greatest
    # lower bound of `self` and `other`: the type describing values that satisfy
    # BOTH. Unlike #>>, it is order-independent and not subtype-checked. The
    # reducer (Subtyping.intersect) narrows where it can — intersecting Ranges/
    # Sets (`Integer[2..] & Integer[0..100]` == `Integer[2..100]`), covariant
    # containers, and distributing over unions — and collapses a PROVABLY-empty
    # intersection to `Types::Never` (`Integer[2..10] & Integer[11..100]`,
    # `String & Integer`). When it can prove neither a narrowing nor emptiness it
    # falls back to `And.new` — a runtime intersection where both sides must pass.
    #
    # @param other [Composable]
    # @return [Composable]
    def &(other)
      other = Composable.wrap(other)
      Plumb::Subtyping.intersect(self, other) || And.new(self, other)
    end

    # Transform value. Requires specifying the resulting type of the value after transformation.
    # @example
    #   Types::String.transform(Types::Symbol, &:to_sym)
    #
    # Shorthand: a single conversion symbol (see COERCION_METHODS) expands to a
    # typed transform to the method's result type, using the symbol as the
    # callable. When the input's base Ruby type is known, it also validates that
    # the type actually responds to the method.
    # @example
    #   Types::String.transform(:to_i)   # => Transform to Integer, via :to_i
    #   Types::Integer.transform(:to_sym) # raises: Integer has no #to_sym
    #
    # @param target_type [Class, Symbol] the output type, or a conversion symbol
    # @param callable [#call, nil] a callable that will be applied to the value, or nil if block provided
    # @param block [Proc] a block that will be applied to the value, or nil if callable provided
    # @return [Transform]
    def transform(target_type, callable = nil, &block)
      if target_type.is_a?(::Symbol) && callable.nil? && block.nil? && (out = COERCION_METHODS[target_type])
        return coercion_transform(target_type, out)
      end

      # Explicit output type + a coercion symbol as the callable
      # (eg. `#transform(::Numeric, :to_f)`). Since the symbol's result type is
      # known, we can compare it against the declared output at composition time:
      #  - `ret <= target_type`  => the produced value is always within the
      #    declared type, so the runtime output check is redundant (guaranteed).
      #  - `ret` and `target_type` disjoint (neither is a subtype of the other)
      #    => no value can be an instance of both, so the transform would reject
      #    EVERY input. That's a composition error, not a runtime one — raise now.
      #  - otherwise (`target_type < ret`, a genuine narrowing) => may or may not
      #    hold at runtime; leave the output check to do its job.
      if callable.is_a?(::Symbol) && block.nil? && (ret = COERCION_METHODS[callable])
        guaranteed = false
        if target_type.is_a?(::Module)
          if ret <= target_type
            guaranteed = true
          elsif !(target_type <= ret)
            raise ArgumentError,
                  ":#{callable} produces a #{ret}, which is never a #{target_type}"
          end
        end
        return transform_step(target_type, callable.to_proc, guaranteed:)
      end

      transform_step(target_type, callable || block || Plumb::NOOP)
    end

    # Pass the value through an arbitrary validation
    # @example
    #   type = Types::String.check('must start with "Role:"') { |value| value.start_with?('Role:') }
    #
    # @param errors [String] error message to use when validation fails
    # @param block [Proc] a block that will be applied to the value
    # @return [Constraint]
    def check(errors = 'did not pass the check', &block)
      # A refinement, not a sequence: build the matcher over `self` as its base so
      # the checked value keeps `self`'s type (`User.check { … }` is still a User).
      Constraint.new(block, base: self, error: errors, label: errors)
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
      constrain(ValueClass.new(val))
    end

    # Alias of `#[]`
    # Match a value using `#===`
    # @example
    #   email = Types::String['@']
    #
    # @param args [Array<Object>]
    # @return [Constraint]
    def match(*args)
      # A refinement returns a base-carrying Constraint directly (not an
      # `And(self, matcher)`): the matcher records `self` as its base, so it
      # subtypes and composes as "a `self` narrowed by the matcher". When `self`
      # is the Any top the matcher stands alone (`Any[String]` == the String
      # matcher), preserving the old collapsing behaviour. Routed through
      # Constraint.narrow so stacked Range refinements intersect
      # (`Integer[0..100][10..]` == `Integer[10..100]`).
      Constraint.narrow((is_a?(AnyClass) ? nil : self), *args)
    end

    # Sugar over #match: a splatted list of values becomes a Set membership
    # matcher, so `Integer[1, 2, 3]` == `Integer[Set[1, 2, 3]]` (and composes /
    # reduces like any Set constraint). A single argument is used as-is — a Range,
    # Regexp, Set, class or literal value.
    # @example
    #   Types::String['a', 'b', 'c'] # one of these three strings
    def [](*args) = match(args.size > 1 ? ::Set.new(args) : args.first)

    # Narrow `self` with a constraint. A constraint refines rather than
    # sequences a new type, so this bypasses the #>> composition type-check
    # (eg. `Generic[::URI::HTTP]` narrows a URI to an HTTP URI). When `self` is
    # the Any top type the constraint stands alone (`Any[::String]` == the
    # String matcher), preserving the collapsing that `AnyClass#>>` provides.
    # Applies the same base-type reduction as #>> (see Subtyping.reduce_step), so
    # `Integer[0..40] / Integer[2..10]` re-parents to `Integer[0..40][2..10]`
    # rather than re-checking `::Integer`. `reduce_step` bails for a non-Constraint
    # constraint (eg. #value's ValueClass), leaving the And.
    # @param constraint [Composable]
    # @return [Composable]
    private def constrain(constraint)
      return constraint if is_a?(AnyClass)

      Plumb::Subtyping.reduce_step(self, constraint) || And.new(self, constraint)
    end

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

      # A Node is a transparent wrapper (it only re-labels its node_name): it
      # delegates type-flow to the wrapped type.
      def input_type = type.input_type
      def output_type = type.output_type
      def value_preserving? = type.value_preserving?

      # Inspect as the wrapped type. Constant-assigned nodes (Types::Boolean,
      # Email) are renamed by constant assignment and ignore this; a runtime node
      # (eg. a factored :refined_union) would otherwise show "Composable::Node".
      private def _inspect = type.inspect

      # Two nodes are equal when they wrap the same type with the same
      # node_name and args. The default Composable#== compares #children,
      # but a Node holds its identity in @node_name/@type/@args, so without
      # this every as_node-wrapped type (Email, Boolean, etc.) would compare
      # equal to every other.
      def ==(other)
        other.is_a?(self.class) &&
          other.node_name == node_name &&
          other.type == type &&
          other.args == args
      end
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
    # @param attrs [Hash{Symbol, String => Object}] attribute name => matcher
    def where(attrs)
      unless attrs.is_a?(::Hash) && !attrs.empty?
        raise ArgumentError,
              '#where expects a non-empty Hash of attribute => matcher ' \
              "(eg. `where(size: 1..10)`), got #{attrs.inspect}"
      end

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
        types = Plumb.resolve_base_types(output_type).uniq

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
      transform_step(cns, block || ->(value) { cns.send(factory_method, value) })
    end

    # Build a Transform that validates the input (self), applies a value-level
    # callable, and declares `target_type` as the (validated) output type.
    private def transform_step(target_type, callable, guaranteed: false)
      klass = guaranteed ? GuaranteedTransform : Transform
      # Flip the cursor in place with the transformed value — the transform owns
      # the result it is handed (the argument is evaluated first, reading the
      # pre-transform value), so no fresh Result is needed.
      klass.new(self, Composable.wrap(target_type),
                ->(result) { result.valid!(callable.call(result.value)) })
    end

    # Expand `#transform(:to_i)` into a typed transform to `output_type`, using
    # the conversion symbol itself as the callable. If the input's base Ruby
    # type(s) can be resolved, validate that they define the method (so
    # `Types::Integer.transform(:to_sym)` fails loudly at build time).
    private def coercion_transform(method_name, output_type)
      bases = Plumb.resolve_base_types(self)
      unless bases.empty? || bases.all? { |k| k.is_a?(::Module) && k.method_defined?(method_name) }
        raise Plumb::TypeError,
              "cannot #transform(#{method_name.inspect}): " \
              "#{bases.map(&:inspect).join(' / ')} does not define ##{method_name}"
      end

      # The output type IS the coercion method's result type, so the produced
      # value is guaranteed to match — skip the runtime output check.
      transform_step(output_type, method_name.to_proc, guaranteed: true)
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
require 'plumb/policy'
require 'plumb/metadata'

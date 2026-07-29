# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/typed_step'

module Plumb
  # A value-converting join, built by `Composable#transform` / `#build`.
  # Unlike `And` (a refinement), a `Function` changes the value: it validates
  # the input (`input_type`), applies `fn`, then declares `output_type`
  # as the produced type. The input constraints do NOT carry through to the
  # output, so for subtyping a `Function` is identified by what it *produces*
  # (its `output_type`). See Plumb::Subtyping.subtype?.
  class Function
    include Composable
    include TypedStep

    # Build a typed function from an input => output pair and a
    # callable that produces the new value.
    #
    #   Plumb::Function[String => Integer] { |result| result.valid(result.value.size) }
    #   Plumb::Function[callable, String => Integer]
    #
    # The callable takes and returns a Result (unlike Composable#transform, whose
    # block takes a value). With no types, both ends default to Types::Any and
    # this delegates to .opaque (use that directly if you want an #inspect label).
    # When input and output are the same type and there's nothing to apply, this
    # is just that type, so it's returned as-is.
    #
    # @param args [Array] (in => out), (callable), or (callable, in => out)
    # @yield [Result] Result => Result
    # @return [Composable]
    def self.[](*args, &block)
      input_type = Types::Any
      output_type = Types::Any
      fn = block || NOOP

      case args
      in []
        # no types, no callable: defaults apply
      in [clb, Hash => inout] if clb.respond_to?(:call)
        raise ArgumentError, 'expected a callable or a block, not both' if block

        fn = clb
        input_type, output_type = __set_types(inout)
      in [clb] if clb.respond_to?(:call)
        raise ArgumentError, 'expected a callable or a block, not both' if block

        fn = clb
      in [Hash => inout]
        input_type, output_type = __set_types(inout)
      else
        raise ArgumentError,
              'expected Plumb::Function[input_type => output_type], Plumb::Function[callable] ' \
              "or Plumb::Function[callable, input_type => output_type]. Got #{args.inspect}"
      end

      return input_type if input_type == output_type && fn == NOOP

      if fn == NOOP
        raise ArgumentError,
              "defined a function (#{input_type} -> #{output_type}), but no explicit " \
              "transform block or callable given. \n" \
              "Should be Plumb::Function[#{input_type} => #{output_type}] { |r| r.valid(new_value_here) }"
      end

      return opaque(fn) if input_type == Types::Any && output_type == Types::Any

      new(input_type, output_type, fn)
    end

    # Build an OPAQUE function around a bare `#call(Result) => Result` callable
    # — see #opaque?. This is what `Composable.wrap` produces for anything
    # callable, and the canonical builder for the no-declared-types case:
    # `Function[callable]` is sugar for it and returns the same thing.
    #
    # It exists separately only because it takes an `inspect` label, which `.[]`
    # cannot: declaring any keyword there would make Ruby route the bare hash in
    # `Function[callable, String => Integer]` into keywords ("unknown keyword:
    # String") and break that form.
    #
    # A GuaranteedFunction, because an opaque function's output check IS `Any`,
    # which no value can fail: skipping it is provably redundant rather than a
    # shortcut, which is exactly what that subclass encodes. (The input check is
    # `Any` too and equally redundant, but #call has to run *some* input check
    # for typed functions, so that hop stays.)
    #
    # Takes the callable positionally, or as a block:
    #
    #   Plumb::Function.opaque(some_callable)
    #   Plumb::Function.opaque(inspect: 'filtered') { |result| result.valid(...) }
    #
    # @param callable [#call, nil] Result => Result
    # @param inspect [String, nil] label to #inspect as, instead of the types
    # @param identity [Object, nil] what the step IS, for #==. An opaque function
    #   declares no types, so its callable is all that distinguishes it; pass a
    #   deterministic token when the block is built fresh per call (see
    #   Composable#invoke).
    # @yield [Result] Result => Result
    # @return [GuaranteedFunction]
    def self.opaque(callable = nil, inspect: nil, identity: nil, &block)
      raise ArgumentError, 'expected a callable or a block, not both' if callable && block

      fn = callable || block
      raise ArgumentError, 'expected a callable or a block' unless fn.respond_to?(:call)

      GuaranteedFunction.new(Types::Any, Types::Any, fn, inspect:, identity:)
    end

    def self.__set_types(inout)
      return [Types::Any, Types::Any] if inout.empty?
      raise ArgumentError, 'expected single key input_type => output_type' if inout.size > 1

      input_type = Composable.wrap(inout.keys.first)
      output_type = Composable.wrap(inout.values.first)
      [input_type, output_type]
    end
    private_class_method :__set_types

    # `fn` is the value-level callable — `#call(Result) => Result`. Exposed so
    # the Decorator can rebuild the node around it, and so an opaque function
    # can be resolved back to the object it wraps (see Plumb::Attributes.struct_class).
    attr_reader :children, :input_type, :output_type, :fn, :identity

    # @param inspect [String, nil] label to #inspect as, instead of the types
    # @param identity [Object, nil] what this function IS, for `#==` — see #==.
    #   Defaults to `fn`, which is correct whenever `fn` is the caller's own
    #   callable rather than a wrapper built around it.
    def initialize(input_type, output_type, fn = Plumb::NOOP, inspect: nil, identity: nil)
      @input_type = input_type
      @output_type = output_type
      @fn = fn
      @inspect_label = inspect
      @identity = identity || fn
      @children = [input_type, output_type].freeze
      freeze
    end

    # Equal when they declare the same types AND apply the same transformation.
    #
    # The default Composable#== compares #children, which for a Function is only
    # `[input_type, output_type]` — so it called any two `String -> Integer` steps
    # equal regardless of what they do, and any two OPAQUE functions equal regardless
    # of their callable. A reducer reading #== as node identity then dropped one:
    # `wrap(proc_a) & wrap(proc_b)` returned just `proc_a`.
    #
    # Compared on #identity, not #fn, because #transform wraps the caller's callable in
    # a FRESH lambda per call — comparing #fn would make two identically-built
    # transforms unequal, and with them every schema containing one. #identity is the
    # caller's own callable, or a deterministic token the builder chose (see
    # Composable#build), so two anonymous blocks still compare unequal.
    def ==(other)
      other.is_a?(self.class) &&
        other.input_type == input_type &&
        other.output_type == output_type &&
        other.identity == identity
    end

    # A Function's #children are [input_type, output_type], so rebuilding it around
    # new ones also has to carry the callable, the inspect label and the #==
    # identity — none of which a caller can see. @see Plumb::NodeMapper
    def with_children(children)
      self.class.new(children[0], children[1], @fn, inspect: @inspect_label, identity: @identity)
    end

    private def _inspect
      @inspect_label || %((#{@input_type.inspect} -> #{@output_type.inspect}))
    end

    def call(result)
      result.map(@input_type).map(@fn).map(@output_type)
    end

    # Fuse `self >> other` into a single Function running both fns, dropping
    # the redundant runtime checks at the boundary: `(A -> B) >> (B -> C)`
    # becomes `(A -> C)` — the intermediate `B` was proven here, at build time.
    # Returns nil (no fusion) unless:
    #   - both #calls are the standard input->fn->output mapping (see #fusible?);
    #   - what self produces is a DIRECT subtype of what other declares as
    #     input. check_composable! is looser — it relaxes container fields via
    #     accepted_type (the `encode >> decode` case), and there other's input
    #     check does real per-field work and must keep running;
    #   - the dropped checks are value-preserving: a coercing boundary type
    #     changes the value, so it must keep running. self's output check needs
    #     this only when it runs at all (see TypedStep#checks_output?).
    def fuse_with(other)
      return nil unless fusable_step? && other.fusable_step?
      return nil unless Plumb::Subtyping.subtype?(@output_type, other.input_type)
      return nil unless Plumb::Subtyping.value_preserving?(other.input_type)
      return nil unless !checks_output? || Plumb::Subtyping.value_preserving?(@output_type)

      fn1 = @fn
      fn2 = other.fn
      # Rebuild as one of the two standard classes, not `other.class`: a node is
      # fusable because it kept #call, which says nothing about its constructor,
      # and this one takes (input, output, fn). What has to survive is whether the
      # final output check still runs — so ask `other`, which may not be a
      # Function at all (see Implementation::TypeInterface).
      klass = other.checks_output? ? Function : GuaranteedFunction
      klass.new(@input_type, other.output_type, ->(result) { result.map(fn1).map(fn2) },
                identity: [identity, other.identity])
    end

    # DERIVED, not declared: this family's #call is Function's full
    # input -> fn -> output or GuaranteedFunction's input -> fn (whose missing
    # output check is provably redundant, not skipped). Anything else replaced it.
    #
    # Asking the method table rather than trusting a class list makes the answer
    # fail-safe — a new subclass with custom semantics is excluded because it
    # overrode #call, not because someone remembered to exclude it. FilteredHash
    # (per-field validation, neither boundary check) is caught that way, so this
    # file no longer has to know that class exists.
    # @see Plumb::TypedStep#fusable_step?
    def standard_call?
      owner = method(:call).owner
      owner.equal?(Function) || owner.equal?(GuaranteedFunction)
    end
  end

  # A Function whose output check is known *at build time* to be redundant, so
  # it is simply not run. Two ways to earn that: the proc provably produces
  # output_type (eg. a `:to_i` coercion always yields an Integer), or the
  # output_type is `Any`, which nothing can fail — the opaque case, see
  # Function.opaque. Choosing the class at build time means
  # #call carries no per-call `guaranteed?` branch — the check is simply absent.
  # It inherits Function's node_name (:function) and `is_a?(Function)`, so
  # visitors, JSON-schema, subtyping and the decorator treat it as a Function;
  # only the produced value's output re-validation is dropped. @output_type is
  # still kept as metadata (inference / JSON schema / subtyping).
  class GuaranteedFunction < Function
    def call(result)
      result.map(@input_type).map(@fn)
    end

    # The whole point of the class: no output check runs, so a seam has none to
    # drop here. @see Plumb::TypedStep#checks_output?
    def checks_output? = false
  end
end

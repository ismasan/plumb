# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  # A value-converting join, built by `Composable#transform` / `#build`.
  # Unlike `And` (a refinement), a `Function` changes the value: it validates
  # the input (`input_type`), applies `fn`, then declares `output_type`
  # as the produced type. The input constraints do NOT carry through to the
  # output, so for subtyping a `Function` is identified by what it *produces*
  # (its `output_type`). See Plumb::Subtyping.subtype?.
  class Function
    include Composable

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
    #   declares no types at all, so its callable is ALL that distinguishes it —
    #   pass a deterministic token when the block is built fresh on each call but
    #   the step it implements is always the same (see Composable#invoke).
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

    # Two functions are equal when they declare the same types AND apply the same
    # transformation.
    #
    # The default Composable#== compares #children, which for a Function is only
    # `[input_type, output_type]` — so it called ANY two `String -> Integer` steps
    # equal regardless of what they do, and any two OPAQUE functions equal
    # regardless of their callable (both ends being Any). A reducer that reads #==
    # as node identity then silently dropped one of them: `wrap(proc_a) &
    # wrap(proc_b)` returned just `proc_a`, and one of the two checks vanished.
    #
    # Compared on #identity, not #fn: #transform wraps the caller's callable in a
    # FRESH lambda per call, so comparing #fn would make two identically-built
    # transforms unequal — and with them every schema containing one. #identity is
    # the caller's own callable, or whatever deterministic token the builder chose
    # (see Composable#build). So a transform built the same way twice stays equal,
    # while two anonymous blocks — which cannot be proven equivalent — do not.
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

    # An OPAQUE function wraps a callable whose types are unknown — both ends
    # are Any (top), which is what `Composable.wrap` builds around any bare
    # `#call(Result) => Result` object. Every other construction path (#transform,
    # #build, coercions, Encoder.step) declares at least an output type, so this
    # identifies exactly "a wrapped callable, not a typed conversion". Callers
    # that need to reach the wrapped object, distinguish it from a real
    # transform, or refuse to optimise across it use this.
    def opaque? = @input_type == Types::Any && @output_type == Types::Any

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
    #     this only when it exists at all (a GuaranteedFunction carries none).
    def fuse_with(other)
      return nil unless fusible?(self) && fusible?(other)
      return nil unless Plumb::Subtyping.subtype?(@output_type, other.input_type)
      return nil unless Plumb::Subtyping.value_preserving?(other.input_type)
      return nil unless is_a?(GuaranteedFunction) || Plumb::Subtyping.value_preserving?(@output_type)

      fn1 = @fn
      fn2 = other.fn
      # other.class keeps Guaranteed-ness: the final output check survives iff
      # `other` carried one.
      other.class.new(@input_type, other.output_type, ->(result) { result.map(fn1).map(fn2) },
                      identity: [identity, other.identity])
    end

    # Is `node` eligible to fuse at all? Two requirements.
    #
    # Its #call must be exactly the standard input->fn->output mapping for its
    # checks to be droppable — an exact-class whitelist (instance_of?), not
    # is_a?: FilteredHash is a Function subclass whose custom #call skips the
    # input check, so it must not fuse. GuaranteedFunction is listed separately
    # because instance_of? never matches through inheritance.
    #
    # And it must not be OPAQUE. Two Any-ended functions would technically fuse
    # (`Any <= Any`), but the only checks dropped are no-ops, so there is nothing
    # to win — while fusing would hide both wrapped callables behind a composite
    # proc, where #fn can no longer reach them (see Attributes.struct_class).
    private def fusible?(node)
      (node.instance_of?(Function) || node.instance_of?(GuaranteedFunction)) && !node.opaque?
    end

    # A Function's subtyping identity is what it produces — its declared,
    # distinct output_type. See Plumb::Subtyping.subtype? and Composable#subtype_identity.
    def subtype_identity = @output_type

    # As a `left >> self` consumer, a Function accepts what its INPUT type
    # accepts — not the input node verbatim. When the input is a Hash/container
    # whose fields are themselves converting (eg. a codec's decode schema, whose
    # `flags` field is a `String -> Integer` step), the accepted type is that
    # input relaxed per field to the type it consumes. This lets an encode
    # pipeline compose with the matching decode pipeline (`encode >> decode`):
    # both meet at the same input type. Mirrors HashClass#accepted_type.
    def accepted_type = Plumb::Subtyping.accepted_type(@input_type)
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
  end

  # The computation-AST name for the same node: a TRANSFORM is the value-changing
  # morphism, as opposed to a CHECK (a Constraint — a partial identity that
  # narrows the type but returns the value untouched). `Function` remains the
  # canonical, documented constructor (`Plumb::Function[String => Integer]`).
  Transform = Function
end

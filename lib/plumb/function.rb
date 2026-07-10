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
    # block takes a value). With no types, both ends default to Types::Any.
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

      new(input_type, output_type, fn)
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
    # the Decorator can rebuild the node around it.
    attr_reader :children, :input_type, :output_type, :fn

    def initialize(input_type, output_type, fn = Plumb::NOOP)
      @input_type = input_type
      @output_type = output_type
      @fn = fn
      @children = [input_type, output_type].freeze
      freeze
    end

    private def _inspect
      %((#{@input_type.inspect} -> #{@output_type.inspect}))
    end

    def call(result)
      result.map(@input_type).map(@fn).map(@output_type)
    end

    # A Function's subtyping identity is what it produces — its declared,
    # distinct output_type. See Plumb::Subtyping.subtype? and Composable#subtype_identity.
    def subtype_identity = @output_type

    # As a `left >> self` consumer, a Function accepts what its INPUT type
    # accepts — not the input node verbatim. When the input is a Hash/container
    # whose fields are themselves converting (eg. a codec's decode schema, whose
    # `flags` field is a `String -> Integer` step), the accepted type is that
    # input relaxed per field to the wire type it consumes. This lets an encode
    # pipeline compose with the matching decode pipeline (`encode >> decode`):
    # both meet at the same wire type. Mirrors HashClass#accepted_type.
    def accepted_type = Plumb::Subtyping.accepted_type(@input_type)
  end

  # A Function whose proc is known *at build time* to produce a value of
  # output_type (eg. a `:to_i` coercion always yields an Integer), so the runtime
  # output check is provably redundant. Choosing the class at build time means
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
end

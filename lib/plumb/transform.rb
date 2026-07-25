# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  # A value-converting join, built by `Composable#transform` / `#build`.
  # Unlike `And` (a refinement), a `Transform` changes the value: it validates
  # the input (`input_type`), applies `transform`, then declares `output_type`
  # as the produced type. The input constraints do NOT carry through to the
  # output, so for subtyping a `Transform` is identified by what it *produces*
  # (its `output_type`). See Plumb::Subtyping.subtype?.
  class Transform
    include Composable

    # Build a typed function (a Transform) from an input => output pair and a
    # callable that produces the new value.
    #
    #   Plumb::Transform[String => Integer] { |result| result.valid(result.value.size) }
    #   Plumb::Transform[callable, String => Integer]
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
      transform = block || NOOP

      case args
      in []
        # no types, no callable: defaults apply
      in [clb, Hash => inout] if clb.respond_to?(:call)
        raise ArgumentError, 'expected a callable or a block, not both' if block

        transform = clb
        input_type, output_type = __set_types(inout)
      in [clb] if clb.respond_to?(:call)
        raise ArgumentError, 'expected a callable or a block, not both' if block

        transform = clb
      in [Hash => inout]
        input_type, output_type = __set_types(inout)
      else
        raise ArgumentError,
              'expected Plumb::Transform[input_type => output_type], Plumb::Transform[callable] ' \
              "or Plumb::Transform[callable, input_type => output_type]. Got #{args.inspect}"
      end

      return input_type if input_type == output_type && transform == NOOP

      if transform == NOOP
        raise ArgumentError,
              "defined a function (#{input_type} -> #{output_type}), but no explicit " \
              "transform block or callable given. \n" \
              "Should be Plumb::Transform[#{input_type} => #{output_type}] { |r| r.valid(new_value_here) }"
      end

      new(input_type, output_type, transform)
    end

    def self.__set_types(inout)
      return [Types::Any, Types::Any] if inout.empty?
      raise ArgumentError, 'expected single key input_type => output_type' if inout.size > 1

      input_type = Composable.wrap(inout.keys.first)
      output_type = Composable.wrap(inout.values.first)
      [input_type, output_type]
    end
    private_class_method :__set_types

    # `transform_proc` (not `transform`, which is Composable's builder method)
    # exposes the value-level callable so the Decorator can rebuild the node.
    attr_reader :children, :input_type, :output_type, :transform_proc

    def initialize(input_type, output_type, transform_proc = Plumb::NOOP)
      @input_type = input_type
      @output_type = output_type
      @transform_proc = transform_proc
      @children = [input_type, output_type].freeze
      freeze
    end

    private def _inspect
      %((#{@input_type.inspect} -> #{@output_type.inspect}))
    end

    def call(result)
      result.map(@input_type).map(@transform_proc).map(@output_type)
    end

    # A Transform's subtyping identity is what it produces — its declared,
    # distinct output_type. See Plumb::Subtyping.subtype? and Composable#subtype_identity.
    def subtype_identity = @output_type
  end

  # A Transform whose proc is known *at build time* to produce a value of
  # output_type (eg. a `:to_i` coercion always yields an Integer), so the runtime
  # output check is provably redundant. Choosing the class at build time means
  # #call carries no per-call `guaranteed?` branch — the check is simply absent.
  # It inherits Transform's node_name (:transform) and `is_a?(Transform)`, so
  # visitors, JSON-schema, subtyping and the decorator treat it as a Transform;
  # only the produced value's output re-validation is dropped. @output_type is
  # still kept as metadata (inference / JSON schema / subtyping).
  class GuaranteedTransform < Transform
    def call(result)
      result.map(@input_type).map(@transform_proc)
    end
  end
end

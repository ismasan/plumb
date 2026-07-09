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

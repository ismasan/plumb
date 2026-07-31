# frozen_string_literal: true

module Plumb
  class Metadata
    include Composable

    attr_reader :type

    def initialize(type, metadata)
      @type = type
      @metadata = type.metadata.merge(metadata)
      freeze
    end

    # Identified by the wrapped type as well as the merged metadata. Two types can
    # carry identical metadata and still describe different values — a Constraint
    # contributes none of its own, so `Integer[1..10]` and `Integer[100..200]`
    # labelled alike would otherwise compare equal, and `==` is what
    # Plumb::Subtyping.subtype? and the Optimizer consult before their
    # #identity_wrapper? guard.
    def ==(other)
      other.instance_of?(self.class) && type == other.type && @metadata == other.metadata
    end

    def metadata(data = Undefined)
      if data == Undefined
        @metadata
      else
        Metadata.new(@type, @metadata.merge(data))
      end
    end

    # Metadata is a transparent wrapper: it delegates type-flow to the wrapped
    # type.
    def input_type = type.input_type
    def output_type = type.output_type

    def call(result) = type.call(result)

    private def _inspect = "Metadata[#{type}, #{@metadata.inspect}]"
  end
end

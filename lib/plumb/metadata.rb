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

    def ==(other)
      other.is_a?(self.class) && @metadata == other.metadata
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

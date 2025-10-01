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

    def call(result) = result

    private def _inspect = "Metadata[#{type}, #{@metadata.inspect}]"
  end
end

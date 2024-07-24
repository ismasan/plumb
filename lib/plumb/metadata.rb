# frozen_string_literal: true

module Plumb
  class Metadata
    include Composable

    attr_reader :metadata

    def initialize(metadata)
      @metadata = metadata
      freeze
    end

    def ==(other)
      other.is_a?(self.class) && @metadata == other.metadata
    end

    def call(result) = result

    private def _inspect = "Metadata[#{@metadata.inspect}]"
  end
end

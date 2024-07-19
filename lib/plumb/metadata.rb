# frozen_string_literal: true

module Plumb
  class Metadata
    include Composable

    attr_reader :metadata

    def initialize(metadata)
      @metadata = metadata
      freeze
    end

    def call(result) = result

    private def _inspect = "Metadata[#{@metadata.inspect}]"
  end
end

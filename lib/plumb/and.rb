# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class And
    include Composable

    attr_reader :children, :input_type, :output_type

    def initialize(left, right, transform = Plumb::NOOP)
      @input_type = left
      @output_type = right
      @transform = transform
      @children = [left, right].freeze
      freeze
    end

    private def _inspect
      %((#{@input_type.inspect} >> #{@output_type.inspect}))
    end

    def call(result)
      result.map(@input_type).map(@transform).map(@output_type)
    end
  end
end

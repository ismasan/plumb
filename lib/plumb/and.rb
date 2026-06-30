# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class And
    include Composable

    attr_reader :children, :input_type, :output_type

    # A refinement/sequencing join, built by `Composable#>>`. Both sides
    # validate the *same* value (no conversion), so an `And` is the
    # intersection of its children: the longer the chain, the narrower the
    # type. A value-converting step is a `Transform` instead (see
    # lib/plumb/transform.rb).
    def initialize(left, right)
      @input_type = left
      @output_type = right
      @children = [left, right].freeze
      freeze
    end

    private def _inspect
      %((#{@input_type.inspect} >> #{@output_type.inspect}))
    end

    def call(result)
      result.map(@input_type).map(@output_type)
    end
  end
end

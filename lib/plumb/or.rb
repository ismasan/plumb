# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Or
    include Composable

    attr_reader :children

    def initialize(left, right)
      @left = Composable.wrap(left)
      @right = Composable.wrap(right)
      @children = [left, right].freeze
      freeze
    end

    # (A | B).input_type == A.input_type | B.input_type
    # (A | B).output_type == A.output_type | B.output_type
    # Computed lazily: building these eagerly in #initialize would recurse
    # forever, since each Or.new would build its own input/output types.
    # TODO: cache these?
    def input_type = Or.new(@left.input_type, @right.input_type)
    def output_type = Or.new(@left.output_type, @right.output_type)

    private def _inspect
      %((#{@left.inspect} | #{@right.inspect}))
    end

    def call(result)
      left_result = @left.call(result)
      return left_result if left_result.valid?

      right_result = @right.call(result)
      if right_result.valid?
        right_result
      else
        # Decrease Array allocations slightly
        # OR can be really expensive in composite ORed types
        left_errors = left_result.errors.is_a?(Array) ? left_result.errors : [left_result.errors]
        right_errors = right_result.errors.is_a?(Array) ? right_result.errors.first : right_result.errors
        left_errors << right_errors

        right_result.invalid(errors: left_errors)
      end
    end
  end
end

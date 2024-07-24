# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Or
    include Composable

    attr_reader :left, :right, :children

    def initialize(left, right)
      @left = left
      @right = right
      @children = [left, right].freeze
      freeze
    end

    private def _inspect
      %((#{@left.inspect} | #{@right.inspect}))
    end

    def call(result)
      left_result = @left.call(result)
      return left_result if left_result.valid?

      right_result = @right.call(result)
      right_result.valid? ? right_result : result.invalid(errors: [left_result.errors, right_result.errors].flatten)
    end
  end
end

# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class And
    include Composable

    attr_reader :left, :right, :children

    def initialize(left, right)
      @left = left
      @right = right
      @children = [left, right].freeze
      freeze
    end

    private def _inspect
      %((#{@left.inspect} >> #{@right.inspect}))
    end

    def call(result)
      result.map(@left).map(@right)
    end
  end
end

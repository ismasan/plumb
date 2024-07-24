# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Build
    include Composable

    attr_reader :children

    def initialize(type, factory_method: :new, &block)
      @type = type
      @block = block || ->(value) { type.send(factory_method, value) }
      @children = [type].freeze
      freeze
    end

    def call(result) = result.valid(@block.call(result.value))

    private def _inspect = "Build[#{@type.inspect}]"
  end
end

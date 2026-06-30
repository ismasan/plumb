# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Step
    include Composable

    attr_reader :_metadata, :children

    def initialize(callable = nil, inspect = nil, &block)
      @_metadata = callable.respond_to?(:metadata) ? callable.metadata : BLANK_HASH
      @callable = callable || block
      @children = [@callable].freeze
      @inspect = inspect || @callable.inspect
      freeze
    end

    def call(result)
      @callable.call(result)
    end

    # A raw Step wraps an arbitrary callable, so its input and output types are
    # unknown — Any (top). This opts it out of #>> composition type-checks.
    def input_type = Types::Any
    def output_type = Types::Any

    private

    def _inspect = "Step[#{@inspect}]"
  end
end

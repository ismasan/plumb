# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Step
    include Composable

    attr_reader :_metadata

    def initialize(callable = nil, inspect = nil, &block)
      @_metadata = callable.respond_to?(:metadata) ? callable.metadata : BLANK_HASH
      @callable = callable || block
      @inspect = inspect || @callable.inspect
      freeze
    end

    def call(result)
      @callable.call(result)
    end

    private

    def _inspect = "Step[#{@inspect}]"
  end
end

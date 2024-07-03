# frozen_string_literal: true

require 'plumb/steppable'

module Plumb
  class Step
    include Steppable

    attr_reader :_metadata

    def initialize(callable = nil, &block)
      @_metadata = callable.respond_to?(:metadata) ? callable.metadata : BLANK_HASH
      @callable = callable || block
      freeze
    end

    def call(result)
      @callable.call(result)
    end

    private

    def _inspect = "Step[#{@callable.inspect}]"
  end
end

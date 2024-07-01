# frozen_string_literal: true

require 'plumb/steppable'

module Plumb
  class Build
    include Steppable

    attr_reader :type

    def initialize(type, factory_method: :new, &block)
      @type = type
      @block = block || ->(value) { type.send(factory_method, value) }
    end

    def call(result) = result.valid(@block.call(result.value))
  end
end

# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Transform
    include Composable

    attr_reader :children

    def initialize(target_type, callable)
      @target_type = target_type
      @callable = callable || Plumb::NOOP
      @children = [target_type].freeze
      freeze
    end

    def call(result)
      result.valid(@callable.call(result.value))
    end

    private

    def _inspect = "->(#{@target_type.inspect})"
  end
end

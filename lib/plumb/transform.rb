# frozen_string_literal: true

require 'plumb/steppable'

module Plumb
  class Transform
    include Steppable

    attr_reader :target_type

    def initialize(target_type, callable)
      @target_type = target_type
      @callable = callable || Plumb::NOOP
      freeze
    end

    def call(result)
      result.valid(@callable.call(result.value))
    end

    private

    def _inspect = "->(#{@target_type.inspect})"
  end
end

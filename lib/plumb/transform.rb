# frozen_string_literal: true

require 'plumb/steppable'

module Plumb
  class Transform
    include Steppable

    attr_reader :target_type

    def initialize(target_type, callable)
      @target_type = target_type
      @callable = callable
    end

    def call(result)
      result.success(@callable.call(result.value))
    end
  end
end

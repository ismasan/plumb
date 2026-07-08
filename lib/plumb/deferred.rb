# frozen_string_literal: true

require 'thread'

module Plumb
  class Deferred
    include Composable

    def initialize(definition)
      @lock = Mutex.new
      @definition = definition
      @cached_type = nil
      # freeze
    end

    def call(result)
      type.call(result)
    end

    def type
      @lock.synchronize do
        @cached_type = @definition.call
        self.define_singleton_method(:type) do
          @cached_type
        end
        @cached_type
      end
    end
  end
end


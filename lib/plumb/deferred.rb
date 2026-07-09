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
        @cached_type ||= @definition.call
        # Release the definition closure: it can capture large scopes (eg. a
        # codec rewriter and the type graph it walked) that would otherwise
        # stay reachable for the life of this node.
        @definition = nil
        self.define_singleton_method(:type) do
          @cached_type
        end
        @cached_type
      end
    end
  end
end


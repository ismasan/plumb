# frozen_string_literal: true

require 'thread'

module Parametric
  module V2
    class Deferred
      include Steppable

      def initialize(definition)
        @lock = Mutex.new
        @definition = definition
        @cached_type = nil
      end

      def ast
        [:deferred, BLANK_HASH, BLANK_ARRAY]
      end

      private def cached_type
        @lock.synchronize do
          @cached_type = @definition.call
          self.define_singleton_method(:cached_type) do
            @cached_type
          end
          @cached_type
        end
      end

      private def _call(result)
        cached_type.call(result)
      end
    end
  end
end

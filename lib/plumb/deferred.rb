# frozen_string_literal: true

require 'thread'

module Plumb
  class Deferred
    include Composable

    def initialize(definition)
      @lock = Mutex.new
      @definition = definition
      @cached_type = nil
      # Separate from @lock: materializing the accepted type reaches back here while
      # its own #type holds @lock.
      @accepted_lock = Mutex.new
      @accepted_type = nil
      # freeze
    end

    # Deferred nodes use identity equality to avoid materializing recursive types.
    # @param other [Object]
    # @return [Boolean]
    def ==(other) = equal?(other)

    def call(result)
      type.call(result)
    end

    # What the materialized type accepts, as another Deferred, so a forward reference
    # isn't resolved early. Memoized, so a self-reference in the body maps back to it
    # and the recursion closes. Without it a Deferred accepts ITSELF, so a codec's
    # recursive encode rewrite is checked against its own encoded form, and rejected.
    def accepted_type
      @accepted_lock.synchronize do
        @accepted_type ||= Deferred.new(-> { Plumb::Subtyping.accepted_type(type) }).tap { |d| d.accepts_itself! }
      end
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

    protected

    # What an accepted type accepts is itself.
    def accepts_itself!
      @accepted_type = self
    end
  end
end

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

    # Identified by object identity. A Deferred stands in for a type it has not
    # materialized yet, so it exposes no #children — structural equality would
    # therefore compare two empty child lists and find EVERY Deferred equal to
    # every other. Forcing #type here to compare what they materialize is not an
    # option either: on a self-referential type (the reason Deferred exists) that
    # recurses forever.
    #
    # Nothing is lost by being conservative here. Plumb::Subtyping.subtype?
    # unwraps a Deferred and relates what it materializes, breaking cycles
    # coinductively — so the relation still sees through two distinct Deferreds
    # that describe the same type, even though `==` does not.
    def ==(other) = equal?(other)

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


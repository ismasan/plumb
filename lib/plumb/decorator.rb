# frozen_string_literal: true

require 'plumb/node_mapper'

module Plumb
  # A class to help decorate all or some types in a
  # type composition.
  # Example:
  #   Type = Types::Array[Types::String | Types::Integer]
  #   Decorated = Plumb::Decorator.(Type) do |type|
  #     if type.is_a?(Plumb::ArrayClass)
  #       LoggerType.new(type, 'array')
  #     else
  #       type
  #     end
  #   end
  #
  # The block is called on EVERY node, bottom-up: sub-types are visited (and possibly
  # replaced) before the block sees the node itself. Returning a node unchanged is a
  # no-op, and an unchanged subtree comes back as the identical object.
  #
  # Traversal is {Plumb::NodeMapper}'s, so it reaches a record's fields, a container's
  # element type and the inside of a Metadata / Policy / #as_node wrapper. It stops at
  # a Constraint's base (rebuilding one would drop a custom `#check` message) and at a
  # Deferred (forcing it would loop on a self-referential type).
  class Decorator
    def self.call(type, &block)
      new(block).visit(type)
    end

    def initialize(block)
      @block = block
    end

    # @param type [Composable]
    # @return [Composable]
    def visit(type)
      decorate(NodeMapper.map(type) { |child| visit(child) })
    end

    private

    def decorate(type)
      @block.call(type)
    end
  end
end

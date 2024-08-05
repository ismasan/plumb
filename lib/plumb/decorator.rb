# frozen_string_literal: true

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
      type = case type
             when And
               left, right = visit_children(type)
               And.new(left, right)
             when Or
               left, right = visit_children(type)
               Or.new(left, right)
             when Not
               child = visit_children(type).first
               Not.new(child, errors: type.errors)
             when Policy
               child = visit_children(type).first
               Policy.new(type.policy_name, type.arg, child)
             else
               type
             end

      decorate(type)
    end

    private

    def visit_children(type)
      type.children.map { |child| visit(child) }
    end

    def decorate(type)
      @block.call(type)
    end
  end
end

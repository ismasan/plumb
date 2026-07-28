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
             when Conjunction
               left, right = visit_children(type)
               # type.class keeps And vs Intersection across decoration.
               type.class.new(left, right)
             when Function
               left, right = visit_children(type)
               # type.class preserves a GuaranteedFunction across decoration;
               # carrying #identity keeps a rebuilt-but-unchanged node #== to the
               # original (see Function#==).
               type.class.new(left, right, type.fn, inspect: type.inspect_label,
                                                    identity: type.identity)
             when Disjunction
               left, right = visit_children(type)
               # type.class keeps Or vs Union across decoration.
               type.class.new(left, right)
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

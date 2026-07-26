# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class TupleClass
    include Composable

    attr_reader :children

    def initialize(*children)
      @children = children.map { |t| Composable.wrap(t) }.freeze
      freeze
    end

    def of(*types)
      self.class.new(*types)
    end

    alias [] of

    # A Tuple validates each position through its type, so it preserves the value
    # only when every position type does (a coercing position would change the
    # tuple).
    def value_preserving? = children.all? { |c| Plumb::Subtyping.value_preserving?(c) }

    # Rebuild around new children (see Plumb::Subtyping.map_children).
    def with_children(children) = of(*children)

    # As a consumer, a Tuple accepts each position relaxed to what that
    # position's type accepts (see HashClass#accepted_type).
    def accepted_type = Plumb::Subtyping.map_children(self) { |c| Plumb::Subtyping.accepted_type(c) }

    # The value you GET after validating each position: every position type
    # resolved to what it produces (mirror of #accepted_type).
    def output_type = Plumb::Subtyping.map_children(self) { |c| Plumb::Subtyping.resolved_output(c) }

    def call(result)
      return result.invalid!(errors: 'must be an Array') unless result.value.is_a?(::Array)
      return result.invalid!(errors: 'must have the same size') unless result.value.size == @children.size

      errors = {}
      values = @children.map.with_index do |type, idx|
        val = result.value[idx]
        r = type.resolve(val)
        errors[idx] = ["expected #{type.inspect}, got #{val.inspect}", r.errors].flatten unless r.valid?
        r.value
      end

      return result.valid!(values) unless errors.any?

      result.invalid!(errors:)
    end

    private

    def _inspect
      "Tuple[#{@children.map(&:inspect).join(', ')}]"
    end
  end
end

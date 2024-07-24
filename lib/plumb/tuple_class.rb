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

    def call(result)
      return result.invalid(errors: 'must be an Array') unless result.value.is_a?(::Array)
      return result.invalid(errors: 'must have the same size') unless result.value.size == @children.size

      errors = {}
      values = @children.map.with_index do |type, idx|
        val = result.value[idx]
        r = type.resolve(val)
        errors[idx] = ["expected #{type.inspect}, got #{val.inspect}", r.errors].flatten unless r.valid?
        r.value
      end

      return result.valid(values) unless errors.any?

      result.invalid(errors:)
    end

    private

    def _inspect
      "Tuple[#{@children.map(&:inspect).join(', ')}]"
    end
  end
end

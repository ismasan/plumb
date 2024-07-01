# frozen_string_literal: true

require 'plumb/steppable'

module Plumb
  class TupleClass
    include Steppable

    attr_reader :types

    def initialize(*types)
      @types = types.map { |t| t.is_a?(Steppable) ? t : Types::Any.value(t) }
    end

    def of(*types)
      self.class.new(*types)
    end

    alias [] of

    private def _inspect
      "#{name}[#{@types.map(&:inspect).join(', ')}]"
    end

    def call(result)
      return result.invalid(errors: 'must be an Array') unless result.value.is_a?(::Array)
      return result.invalid(errors: 'must have the same size') unless result.value.size == @types.size

      errors = {}
      values = @types.map.with_index do |type, idx|
        val = result.value[idx]
        r = type.resolve(val)
        errors[idx] = ["expected #{type.inspect}, got #{val.inspect}", r.errors].flatten unless r.valid?
        r.value
      end

      return result.valid(values) unless errors.any?

      result.invalid(errors:)
    end
  end
end

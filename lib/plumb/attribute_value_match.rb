# frozen_string_literal: true

module Plumb
  class AttributeValueMatch
    include Composable

    attr_reader :type, :attr_name, :value

    def initialize(type, attr_name, value)
      @type = type
      @attr_name = attr_name
      @value = value
      @error = "must have attribute #{attr_name} === #{value.inspect}"
      @inspect_line = %((#{attr_name} === #{value.inspect}))
      freeze
    end

    def metadata = type.metadata

    def call(result)
      return result if value === result.value.public_send(attr_name)

      result.invalid(errors: @error)
    end

    private def _inspect = @inspect_line
  end
end

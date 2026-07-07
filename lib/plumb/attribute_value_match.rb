# frozen_string_literal: true

module Plumb
  class AttributeValueMatch
    include Composable

    attr_reader :type, :attr_name, :value

    def initialize(type, attr_name, value)
      unless attr_name.is_a?(::Symbol) || attr_name.is_a?(::String)
        raise ArgumentError, "attribute name must be a Symbol or String, got #{attr_name.inspect}"
      end

      @type = type
      @attr_name = attr_name
      @value = value
      @error = "must have attribute #{attr_name} === #{value.inspect}"
      @inspect_line = %((#{attr_name} === #{value.inspect}))
      freeze
    end

    # Two attribute constraints are equal when they constrain the same attribute
    # of the same base type to the same value. (The default Composable#== only
    # compares #children, which an AttributeValueMatch doesn't expose, so it
    # would treat every constraint as equal.)
    def ==(other)
      other.is_a?(self.class) &&
        attr_name == other.attr_name &&
        value == other.value &&
        type == other.type
    end

    def metadata = type.metadata

    # An attribute-value constraint narrows by value, so it accepts any input
    # (opts out of #>> composition type-checks).
    def input_type = Types::Any

    # It checks an attribute and returns the value unchanged — a pure refinement.
    def value_preserving? = true

    # Subtyping for an attribute constraint. Against another constraint on the
    # SAME attribute, the base types must be compatible and this constraint's
    # value must be a subtype of the other's — eg. `size: 10` <= `size: 8..100`,
    # but `size: 10..15` </= `size: 11..14`. Against any other type, an
    # attribute-constrained type is simply a subtype of its base type (eg.
    # `Array.where(size: 10) <= Array`).
    def subtype_of?(other)
      if other.is_a?(AttributeValueMatch)
        attr_name == other.attr_name &&
          Plumb::Subtyping.subtype?(type, other.type) &&
          Plumb::Subtyping.value_subtype?(value, other.value)
      else
        Plumb::Subtyping.subtype?(type, other)
      end
    end

    def call(result)
      return result if value === result.value.public_send(attr_name)

      result.invalid!(errors: @error)
    end

    private def _inspect = @inspect_line
  end
end

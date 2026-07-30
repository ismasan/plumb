# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  # A single literal value, matched by `==`.
  #
  # Unlike the other bare matchers — a Constraint with no base, an
  # AttributeValueMatch — this does NOT report `Types::Any` as its #input_type.
  # Those opt out of #>>'s subtype check because they narrow arbitrary input and
  # have no declared domain to check against; a literal's domain is a known
  # singleton, so it keeps the default (`self`) and accepts only its own value.
  # That is what makes `Value['a'] >> Value['b']` raise rather than build a chain
  # no value can satisfy. Narrowing a wider type down to a literal is spelled
  # `#[]` (`Types::String['a']`), which builds the refinement directly.
  class ValueClass
    include Composable

    attr_reader :children

    def initialize(value = Undefined)
      @value = value
      # Pre-build the failure message once (the object is frozen and @value is
      # fixed), so a miss on the hot path — eg. every non-matching branch of a
      # `Value[a] | Value[b]` enum union — doesn't allocate a fresh String.
      # Frozen because it's shared across every failing call (and across threads
      # under Types::Array#concurrent) and only ever read, never mutated.
      @error = "Must be equal to #{value}".freeze
      @children = [value].freeze
      freeze
    end

    def [](value) = self.class.new(value)

    # Matches a specific value and passes it through unchanged.
    def value_preserving? = true

    def call(result)
      @value == result.value ? result : result.invalid!(errors: @error)
    end

    private

    def _inspect = @value.inspect
  end
end

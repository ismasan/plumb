# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class And
    include Composable

    attr_reader :children, :input_type

    # Both sides validate the same value. Normally the refinement's output type is
    # the right side (the narrowing constraint). But if the right side is a
    # transparent predicate (eg. a `#check`), it doesn't determine a type, so the
    # output is the *left*'s output — the base type survives the assertion (so
    # `User.check { … }.output_type` is User, not the opaque predicate).
    def output_type = @output_type.transparent? ? @input_type : @output_type

    # A refinement/sequencing join, built by `Composable#>>`. Both sides
    # validate the *same* value (no conversion), so an `And` is the
    # intersection of its children: the longer the chain, the narrower the
    # type. A value-converting step is a `Transform` instead (see
    # lib/plumb/transform.rb).
    def initialize(left, right)
      @input_type = left
      @output_type = right
      @children = [left, right].freeze
      freeze
    end

    private def _inspect
      %((#{@input_type.inspect} >> #{@output_type.inspect}))
    end

    def call(result)
      result.map(@input_type).map(@output_type)
    end

    # As a consumer a refinement accepts the constraint it actually passes — its
    # resolved output — not its #input_type, which is only the base (left) type
    # and would ignore the refinement (eg. `Integer[1..10].input_type` is just
    # Integer, but it only accepts values in 1..10).
    def accepted_type = Plumb::Subtyping.resolved_output(self)
  end
end

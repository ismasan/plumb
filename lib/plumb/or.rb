# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Or
    include Composable

    attr_reader :children

    def initialize(left, right)
      @left = Composable.wrap(left)
      @right = Composable.wrap(right)
      @children = [@left, @right].freeze
      freeze
    end

    # (A | B).input_type == A.input_type | B.input_type
    # (A | B).output_type == A.output_type | B.output_type
    # Computed lazily: building these eagerly in #initialize would recurse
    # forever, since each Or.new would build its own input/output types.
    # When both children are their own io type (the common leaf case) return
    # self rather than a structurally-equal copy, so Subtyping.resolved_*
    # converges on identity without allocating. Results are memoized per node
    # at the consuming end (Subtyping.resolved_input/resolved_output).
    def input_type
      l = @left.input_type
      r = @right.input_type
      l.equal?(@left) && r.equal?(@right) ? self : Or.new(l, r)
    end

    def output_type
      l = @left.output_type
      r = @right.output_type
      l.equal?(@left) && r.equal?(@right) ? self : Or.new(l, r)
    end

    # A disjunction preserves the value only if EVERY branch does — a branch
    # that transforms (a coercion) changes it when taken. Recurses through the
    # cached accessor so shared subtrees are memoized once.
    def value_preserving? = children.all? { |c| Plumb::Subtyping.value_preserving?(c) }

    private def _inspect
      %((#{@left.inspect} | #{@right.inspect}))
    end

    def call(result)
      # Snapshot the input value: @left may flip the cursor to invalid in place,
      # so we need the original to retry @right on the same object.
      original = result.value

      left_result = @left.call(result)
      return left_result if left_result.valid?

      # Capture left's errors before reusing the cursor — if @left mutated
      # `result` in place, `left_result` IS `result` and the reset below would
      # wipe them.
      left_raw = left_result.errors

      right_result = @right.call(result.reset(original))
      return right_result if right_result.valid?

      # Both branches failed. Merge errors (same flattening as before) and reuse
      # right's already-invalid cursor in place rather than allocating another.
      # OR can be really expensive in composite ORed types.
      left_errors = left_raw.is_a?(Array) ? left_raw : [left_raw]
      right_errors = right_result.errors.is_a?(Array) ? right_result.errors.first : right_result.errors
      left_errors << right_errors

      right_result.invalid!(errors: left_errors)
    end
  end
end

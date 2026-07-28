# frozen_string_literal: true

module Plumb
  # The runtime shared by {Plumb::Or} (left-biased choice) and {Plumb::Union} (the
  # lattice join) — the dual of {Plumb::Conjunction}. Both try `left` and retry
  # `right` with the original value on failure, and differ only in how types flow:
  #
  #   - a CHOICE may have CONVERTING branches, so its ends genuinely differ:
  #     `Integer | String.transform(:to_i)` accepts a String but produces an Integer.
  #   - a UNION is a type — every branch returns its value untouched — so it is its
  #     own output type, needing no #value_preserving? recursion and no rebuild.
  module Disjunction
    # @param left [Composable]
    # @param right [Composable]
    # @return [Union, Or]
    def self.build(left, right)
      if Plumb::Subtyping.value_preserving?(left) && Plumb::Subtyping.value_preserving?(right)
        Union.new(left, right)
      else
        Or.new(left, right)
      end
    end

    attr_reader :children

    # Identical for both nodes, which differ only in how types flow.
    def initialize(left, right)
      @left = Composable.wrap(left)
      @right = Composable.wrap(right)
      @children = [@left, @right].freeze
      freeze
    end

    # (A | B).input_type == A.input_type | B.input_type — shared by both nodes.
    #
    # A Union cannot shortcut this to `self` the way it can #output_type, because a
    # branch may ACCEPT more than it describes: a bare-matcher Constraint reports
    # `input_type` Any, so a factored `String[/d/] | String[/c/]` consumes Any, and a
    # Union claiming to consume only itself would fail `String >> that`.
    #
    # Rebuilt through .build, not the receiver's class: a disjunction may be a
    # computation, but its projections are types, so
    # `(String->Integer | Integer->String).input_type` is a Union and compares equal
    # to a hand-written `String | Integer`.
    #
    # Lazy, or #initialize would recurse building its own io types. Returns self when
    # both children are their own input type, so Subtyping.resolved_input converges on
    # identity without allocating.
    def input_type
      l = @left.input_type
      r = @right.input_type
      l.equal?(@left) && r.equal?(@right) ? self : Disjunction.build(l, r)
    end

    # Rebuild around new branches, RECLASSIFYING by what they are.
    # @see Conjunction#with_children for why this must not preserve the class.
    def with_children(children) = Disjunction.build(children[0], children[1])

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

      # Both branches failed. Combine the two error sets, then reuse right's
      # already-invalid cursor in place rather than allocating another — a union can
      # be expensive in composite ORed types. `right_result.errors` is read BEFORE
      # #invalid! overwrites it.
      merged = Disjunction.merge_errors(left_raw, right_result.errors)
      right_result.invalid!(errors: merged)
    end

    # Combining the errors of failed ALTERNATIVES is a monoid: `nil` is the identity,
    # concatenation the operation. ASSOCIATIVITY is the law that matters — `(A|B)|C`
    # and `A|(B|C)` are the same set of alternatives and owe the same errors, so
    # taking only `errors.first` from the right (as this once did) drops every
    # alternative after the first in a right-nested union.
    #
    # Non-destructive: never appends to the left result's own array, which has already
    # been handed out as an #errors value. Costs one extra Array, and only for three or
    # more alternatives.
    #
    # ONLY for alternatives — a record's or array's errors are a Hash keyed by
    # field/index, which is meaningful structure this is never applied to.
    #
    # @param left [Object, nil] the left alternative's errors
    # @param right [Object, nil] the right alternative's errors
    # @return [Object, nil]
    def self.merge_errors(left, right)
      return right if left.nil?
      return left if right.nil?

      merged = left.is_a?(::Array) ? left.dup : [left]
      right.is_a?(::Array) ? merged.concat(right) : merged.push(right)
      merged
    end
  end
end

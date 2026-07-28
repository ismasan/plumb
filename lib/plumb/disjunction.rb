# frozen_string_literal: true

module Plumb
  # The runtime shared by the two two-branch "either side" nodes: {Plumb::Or}
  # (left-biased choice) and {Plumb::Union} (the lattice join). The dual of
  # {Plumb::Conjunction}.
  #
  # Both execute identically — try `left`, and on failure retry `right` with the
  # original value — and differ only in how types flow:
  #
  #   - a CHOICE has branches that may CONVERT, so it is a computation. Its
  #     branches can accept inputs the join of their outputs would reject
  #     (`Integer | String.transform(:to_i)` accepts a String but produces an
  #     Integer), so its input and output types genuinely differ.
  #   - a UNION is a type: every branch returns its value untouched, so the node
  #     describes exactly "a value in one of these sets" and is its own output.
  #
  # The distinction is decided once, structurally, by {Disjunction.build}.
  #
  # It matters less here than for Conjunction — Or was already close to a lattice
  # join, because #input_type/#output_type map over the branches rather than
  # picking one — but it removes the same class of runtime re-derivation: a Union
  # needs no #value_preserving? recursion over its children and no rebuild of
  # itself in #output_type.
  module Disjunction
    # Build the right node for `left` or `right`.
    #
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

    # (A | B).input_type == A.input_type | B.input_type — shared by both nodes.
    #
    # A Union cannot shortcut this to `self` the way it can #output_type. A branch
    # may ACCEPT more than it describes: a bare-matcher Constraint (`Constraint(/d/)`,
    # no base) reports `input_type` Any, because it narrows arbitrary input rather
    # than gating a type. So `String[/d/] | String[/c/]`, once factored to bare
    # suffixes, consumes Any — and a Union claiming to consume only itself would
    # make `String >> that` fail the composition check.
    #
    # Rebuilt through .build, not the receiver's class: a disjunction may be a
    # computation, but its projections are types. `(String->Integer | Integer->String)`
    # consumes `String | Integer` — a plain join with no conversion left in it — so
    # the projection is a Union and compares equal to a hand-written one.
    #
    # Computed lazily: building it in #initialize would recurse forever, since each
    # node would build its own. When both children are their own input type (the
    # common leaf case) return self rather than a structurally-equal copy, so
    # Subtyping.resolved_input converges on identity without allocating; results are
    # memoized per node at the consuming end.
    def input_type
      l = @left.input_type
      r = @right.input_type
      l.equal?(@left) && r.equal?(@right) ? self : Disjunction.build(l, r)
    end

    # Rebuild around new branches. `self.class` keeps Or vs Union.
    # @see Plumb::NodeMapper
    def with_children(children) = self.class.new(children[0], children[1])

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

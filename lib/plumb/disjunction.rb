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

    # Both nodes wrap and freeze identically — the mixin's thesis is that they differ
    # only in how TYPES flow, so the construction belongs here rather than in two
    # copies.
    def initialize(left, right)
      @left = Composable.wrap(left)
      @right = Composable.wrap(right)
      @children = [@left, @right].freeze
      freeze
    end

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
    # concatenation is the operation. Associativity is the law that matters here —
    # `(A|B)|C` and `A|(B|C)` describe the same set of alternatives, so they owe the
    # same errors.
    #
    # The previous merge took only `errors.first` from the right-hand side, so a
    # right-nested union silently dropped every alternative after the first:
    #
    #   ((A|B)|C).resolve(bad).errors  => [a, b, c]
    #   (A|(B|C)).resolve(bad).errors  => [a, b]        <- c lost
    #
    # Left-nesting hid it, because Ruby's `|` is left-associative — but explicit
    # parens reach it, and so does any rebuild through Disjunction.build.
    #
    # Non-destructive: it never appends to the left result's own array, which has
    # already been handed out as an #errors value. That copy is the only cost —
    # measured at one extra Array per merge, and only for a union of three or more
    # alternatives (a two-branch merge allocates exactly what it always did). It buys
    # not having to reason about who owns an errors array, on a path whose three
    # existing comments are all about in-place mutation hazards.
    #
    # ONLY for alternatives. A record's or an array's errors are a Hash keyed by
    # field/index and stay that way — that structure is meaningful, and this
    # operation is never applied to it.
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

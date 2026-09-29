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

    # Leaf branches under this node, counting through nested disjunctions:
    # `a | b | c` is `(a | b) | c`, with 3.
    attr_reader :branch_count

    # Identical for both nodes, which differ only in how types flow.
    def initialize(left, right)
      @left = Composable.wrap(left)
      @right = Composable.wrap(right)
      @children = [@left, @right].freeze
      @branch_count = [@left, @right].sum { |c| c.is_a?(Disjunction) ? c.branch_count : 1 }
      if @branch_count >= ClassDispatch::MIN_BRANCHES
        @dispatch = ClassDispatch.new(self)
        # Per instance, so a short union keeps the plain #call.
        extend Dispatched
      end
      freeze
    end

    # #dup keeps ivars but not singleton modules (TypeRegistry dups types to rename them).
    def initialize_copy(source)
      super
      extend Dispatched if @dispatch
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

    # What either branch accepts. Not #input_type: that leaves a container branch as
    # is, so `Array[Date] | Nil` composed with its encode rewrite checks an
    # `Array[Date]` against the rewrite's String output, and rejects.
    def accepted_type
      l = branch_accepted(@left)
      r = branch_accepted(@right)
      l.equal?(@left) && r.equal?(@right) ? self : Disjunction.build(l, r)
    end

    # A branch whose input is unknown (a bare pattern matcher) opts out of the
    # composition check, as it does on its own (see Subtyping.check_composable!).
    private def branch_accepted(branch)
      return Types::Any if Plumb::Subtyping.resolved_input(branch).is_a?(AnyClass)

      Plumb::Subtyping.accepted_type(branch)
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

    # #call for a union of ClassDispatch::MIN_BRANCHES or more. It first tries only the
    # branches that could accept the value's class: same result, as the skipped ones
    # would have failed. If those fail too, the plain #call runs to collect every
    # branch's errors, as without dispatch.
    module Dispatched
      def call(result)
        candidates = @dispatch.candidates(result.value.class)
        return super unless candidates

        original = result.value
        i = 0
        while i < candidates.size
          r = candidates[i].call(i.zero? ? result : result.reset(original))
          return r if r.valid?

          i += 1
        end
        super(result.reset(original))
      end
    end

    # Per input class, the leaf branches that could accept a value of that class, in
    # order. A branch's classes are its Subtyping.stable_domain: known only when what it
    # accepts and what it produces share base types, so a converting branch (a
    # Function, a struct, a codec's rewrite) is always a candidate.
    #
    # Only Class domains are used, not Modules: an object can gain a module through
    # #extend, which its #class doesn't show.
    #
    # Built lazily, on first use: resolving branch domains when the union is built would
    # materialize `defer`red forward references.
    class ClassDispatch
      MIN_BRANCHES = 3
      # Beyond this many distinct classes, candidates are recomputed instead of cached.
      MAX_CLASSES = 64
      # Cached for a class whose candidates are all the branches: nothing to skip.
      ALL = :all

      def initialize(node)
        @node = node
        @lock = Mutex.new
        # Replaced, never mutated, so reads need no lock.
        @table = {}.freeze
        @branches = nil
      end

      # @param klass [Class] the input value's class
      # @return [Array<Composable>, nil] candidate branches in order, or nil when none
      #   can be skipped
      def candidates(klass)
        found = @table[klass] || store(klass, compute(klass))
        found.equal?(ALL) ? nil : found
      end

      private

      def compute(klass)
        list = branches.filter_map { |branch, domain| branch if domain.nil? || domain.any? { |d| klass <= d } }
        list.size == branches.size ? ALL : list.freeze
      end

      def store(klass, list)
        @lock.synchronize { @table = @table.merge(klass => list).freeze if @table.size < MAX_CLASSES }
        list
      end

      # [[branch, classes or nil], ...]
      def branches
        @branches || @lock.synchronize do
          @branches ||= leaves(@node).map { |branch| [branch, domain(branch)] }.freeze
        end
      end

      def leaves(node)
        node.children.flat_map { |c| c.is_a?(Disjunction) ? leaves(c) : [c] }
      end

      def domain(branch)
        classes = Plumb::Subtyping.stable_domain(branch)
        classes if classes&.all? { |c| c.is_a?(::Class) }
      end
    end
  end
end

# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Not
    include Composable

    attr_reader :children, :errors

    # Double negation cancels: `Not(Not(X))` is just `X` — it accepts exactly
    # what `X` does. So wrapping an existing Not returns the inner type instead
    # of nesting (covering both `#not` and `Not[]`). A custom error message
    # keeps the Not, since collapsing would discard it.
    def self.new(step = nil, errors: nil)
      wrapped = Composable.wrap(step)
      return wrapped.children.first if errors.nil? && wrapped.is_a?(self)

      super
    end

    # @see Plumb::NodeMapper
    def with_children(children) = self.class.new(children.first, errors: errors)

    def initialize(step = nil, errors: nil)
      @step = Composable.wrap(step)
      @errors = errors || "must not be #{step.inspect}"
      # Store the *wrapped* step (as every container does), so `Not[String]` and
      # `Not[Types::String]` are the same node — and so the subtype engine isn't
      # fooled into treating a raw-class child as an atomic leaf.
      @children = [@step].freeze
      freeze
    end

    # @param step [Object]
    # @return [Not]
    def [](step)
      self.class.new(step)
    end

    # Negation is CONTRAVARIANT: `Not(A) <= Not(B)` exactly when `B <= A`.
    #
    # `Not(A)` accepts everything OUTSIDE A, so the wider the negated type, the
    # narrower the negation. `Not[Numeric]` excludes every number and so is a
    # subtype of `Not[Integer]`, which excludes only integers and still accepts
    # `1.5`. The default covariant-container rule reads the children the other way
    # round and gets both directions wrong.
    def subtype_of?(other)
      return true if self == other
      return Plumb::Subtyping.subtype?(other.children.first, @step) if other.is_a?(Not)

      super
    end

    # A negation checks the value and passes it through untouched — #call only
    # flips validity.
    def value_preserving? = true

    private def _inspect
      %(Not(#{@step.inspect}))
    end

    def call(result)
      result = @step.call(result)
      # In-place inversion — no fork here, the cursor is ours to flip.
      result.valid? ? result.invalid!(errors: @errors) : result.valid!
    end
  end
end

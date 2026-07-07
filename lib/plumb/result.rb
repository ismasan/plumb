# frozen_string_literal: true

module Plumb
  # The value + validity + errors triple that flows through a composition.
  #
  # There are two ways to derive one result from another:
  #
  #   - #valid / #invalid ALLOCATE a fresh Result and leave the receiver
  #     untouched. This is the safe, functional form: use it in custom types, and
  #     anywhere a result may outlive the call or be captured (Streams close over
  #     it lazily; concurrent Arrays hand results between threads). This is the
  #     public API for user-defined steps.
  #
  #   - #valid! / #invalid! FLIP THE RECEIVER in place and return it (no
  #     allocation). Plumb's own built-in steps use these on the hot path to
  #     avoid a Result per node — but only where the input cursor is theirs to
  #     mutate: never on a shared/constant Result, never when the result escapes
  #     into a closure or another thread. The one fork point (Or) snapshots the
  #     value and #resets before retrying its second branch.
  #
  # So built-ins stay allocation-lean while user code (and the concurrency- and
  # laziness-sensitive built-ins) keep the footgun-free copying semantics, at the
  # cost of a few extra allocations there.
  #
  # Valid and Invalid were once separate subclasses; collapsing them into one
  # class with a boolean is what makes the in-place valid<->invalid flip possible
  # (Ruby can't change an object's class).
  class Result
    class << self
      def valid(value = nil)
        new(value, valid: true)
      end

      def invalid(value = nil, errors: nil)
        new(value, valid: false, errors:)
      end

      def wrap(value)
        return value if value.is_a?(Result)

        valid(value)
      end
    end

    attr_reader :value, :errors

    def initialize(value, valid: true, errors: nil)
      @value = value
      @valid = valid
      @errors = errors
    end

    def valid? = @valid
    def invalid? = !@valid

    def inspect
      %(<#{self.class}##{object_id} valid:#{@valid} value:#{value.inspect} errors:#{errors.inspect}>)
    end

    # Allocating, copy-returning form. Safe everywhere: the receiver is untouched.
    def valid(val = value)
      Result.valid(val)
    end

    def invalid(val = value, errors: nil)
      Result.invalid(val, errors:)
    end

    # In-place form: flip THIS result and return self. No allocation. Only for
    # code that owns the cursor (see the class docstring).
    def valid!(val = value)
      @value = val
      @valid = true
      @errors = nil
      self
    end

    def invalid!(val = value, errors: nil)
      @value = val
      @valid = false
      @errors = errors
      self
    end

    # Reset the cursor to a fresh VALID state carrying `val`, in place. The
    # mutating scratch-reuse primitive behind the HashClass/ArrayClass element
    # loops (same as #valid!(val)).
    def reset(val)
      valid!(val)
    end

    def map(callable)
      @valid ? callable.call(self) : self
    end
  end
end

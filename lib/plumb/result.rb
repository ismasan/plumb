# frozen_string_literal: true

module Plumb
  class Result
    class << self
      def valid(value)
        Valid.new(value)
      end

      def invalid(value = nil, errors: nil)
        Invalid.new(value, errors:)
      end

      def wrap(value)
        return value if value.is_a?(Result)

        valid(value)
      end
    end

    attr_reader :value, :errors

    def initialize(value, errors: nil)
      @value = value
      @errors = errors
    end

    def valid? = true
    def invalid? = false

    def inspect
      %(<#{self.class}##{object_id} value:#{value.inspect} errors:#{errors.inspect}>)
    end

    def reset(val)
      @value = val
      @errors = nil
      self
    end

    def valid(val = value)
      Result.valid(val)
    end

    def invalid(val = value, errors: nil)
      Result.invalid(val, errors:)
    end

    class Valid < self
      def map(callable)
        callable.call(self)
      end
    end

    class Invalid < self
      def valid? = false
      def invalid? = true

      def map(_)
        self
      end
    end
  end
end

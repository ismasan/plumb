# frozen_string_literal: true

require 'concurrent'
require 'plumb/steppable'
require 'plumb/result'
require 'plumb/stream_class'

module Plumb
  class ArrayClass
    include Steppable

    attr_reader :element_type

    def initialize(element_type: Types::Any)
      @element_type = Steppable.wrap(element_type)

      freeze
    end

    def of(element_type)
      self.class.new(element_type:)
    end

    alias [] of

    def concurrent
      ConcurrentArrayClass.new(element_type:)
    end

    def stream
      StreamClass.new(element_type:)
    end

    def call(result)
      return result.invalid(errors: 'is not an Array') unless ::Array === result.value

      values, errors = map_array_elements(result.value)
      return result.valid(values) unless errors.any?

      result.invalid(errors:)
    end

    private

    def _inspect
      %(Array[#{element_type}])
    end

    def map_array_elements(list)
      # Reuse the same result object for each element
      # to decrease object allocation.
      # Steps might return the same result instance, so we map the values directly
      # separate from the errors.
      element_result = BLANK_RESULT.dup
      errors = {}
      values = list.map.with_index do |e, idx|
        re = element_type.call(element_result.reset(e))
        errors[idx] = re.errors unless re.valid?
        re.value
      end

      [values, errors]
    end

    class ConcurrentArrayClass < self
      private

      def map_array_elements(list)
        errors = {}

        values = list
                 .map { |e| Concurrent::Future.execute { element_type.resolve(e) } }
                 .map.with_index do |f, idx|
          re = f.value
          errors[idx] = f.reason if f.rejected?
          re.value
        end

        [values, errors]
      end
    end
  end
end

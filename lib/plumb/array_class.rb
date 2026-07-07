# frozen_string_literal: true

require 'concurrent'
require 'plumb/composable'
require 'plumb/result'
require 'plumb/stream_class'

module Plumb
  class ArrayClass
    include Composable

    attr_reader :children

    def initialize(element_type: Types::Any)
      @element_type = Composable.wrap(element_type)
      @children = [@element_type].freeze

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

    def filtered
      Constraint.new(::Array) >> Step.new(nil, "Array[#{element_type}].filtered") do |result|
        arr = result.value.each.with_object([]) do |e, memo|
          r = element_type.resolve(e)
          memo << r.value if r.valid?
        end
        result.valid!(arr)
      end
    end

    def call(result)
      return result.invalid!(errors: 'is not an Array') unless ::Array === result.value

      # map_array_elements uses its own element scratch (below), so `result` is
      # untouched until here — flip it in place rather than allocating a fresh one.
      values, errors = map_array_elements(result)
      return result.valid!(values) unless errors.any?

      result.invalid!(values, errors:)
    end

    private

    attr_reader :element_type

    def _inspect
      %(Array[#{element_type}])
    end

    def map_array_elements(result)
      # Reuse the INCOMING cursor as the per-element scratch (capturing the array
      # first): each element flips it in place via #reset, and #call flips it a
      # final time to the collected values — so a sequential Array validates with
      # zero Result allocations of its own. Steps may return the same result
      # instance, so map values/errors out immediately rather than holding `re`.
      #
      # Element types that produce a value which is lazily consumed later (a
      # Stream) must not close over this reused cursor — StreamClass#call
      # snapshots its source for exactly this reason (see there).
      array = result.value
      errors = Hash.new(capacity: array.size)
      values = array.map.with_index do |e, idx|
        re = element_type.call(result.reset(e))
        errors[idx] = re.errors unless re.valid?
        re.value
      end

      [values, errors]
    end

    class ConcurrentArrayClass < self
      private

      def map_array_elements(result)
        errors = {}

        values = result.value
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

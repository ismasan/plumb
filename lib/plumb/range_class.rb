# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class RangeClass
    include Composable

    attr_reader :children

    def initialize(member_type = Types::Any)
      @member_type = Composable.wrap(member_type)
      @children = [@member_type].freeze
      freeze
    end

    def of(member_type)
      self.class.new(member_type)
    end

    alias [] of

    # #call only validates the Range's endpoints against the member type — it
    # never coerces or rebuilds the Range — so a Range type always returns its
    # input unchanged, regardless of member. This lets `#|` absorb a narrower
    # branch (`Range[Integer] | Range[1..10]` -> `Range[Integer]`) and `#>>`
    # drop a redundant re-check.
    def value_preserving? = true

    def call(result)
      return result.invalid!(errors: 'must be a Range') unless result.value.is_a?(::Range)

      range = result.value
      [range.begin, range.end].compact.each do |endpoint|
        r = @member_type.resolve(endpoint)
        return result.invalid!(errors: r.errors) unless r.valid?
      end

      result
    end

    private

    def _inspect = %(Range[#{@member_type}])
  end
end

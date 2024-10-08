# frozen_string_literal: true

require 'thread'
require 'plumb/composable'

module Plumb
  # A stream that validates each element.
  # Example:
  #   row = Types::Tuple[String, Types::Lax::Integer]
  #   csv_stream = Types::Stream[row]
  #
  #   stream = csv_stream.parse(CSV.new(File.new('data.csv')).to_enum)
  #   stream.each |result|
  #     result.valid? # => true
  #     result.value # => ['name', 10]
  #   end
  class StreamClass
    include Composable

    attr_reader :children

    # @option element_type [Composable] the type of the elements in the stream
    def initialize(element_type: Types::Any)
      @element_type = Composable.wrap(element_type)
      @children = [@element_type].freeze
      freeze
    end

    # return a new Stream definition.
    # @param element_type [Composable] the type of the elements in the stream
    def [](element_type)
      self.class.new(element_type:)
    end

    # The [Step] interface
    # @param result [Result::Valid]
    # @return [Result::Valid, Result::Invalid]
    def call(result)
      return result.invalid(errors: 'is not an Enumerable') unless result.value.respond_to?(:each)

      enum = Enumerator.new do |y|
        result.value.each do |e|
          y << @element_type.resolve(e)
        end
      end

      result.valid(enum)
    end

    # @return [Step] a step that resolves to an Enumerator that filters out invalid elements
    def filtered
      self >> Step.new(nil, 'filtered') do |result|
        set = result.value.lazy.filter_map { |e| e.value if e.valid? }
        result.valid(set)
      end
    end

    private

    def _inspect = "Stream[#{@element_type.inspect}]"
  end
end

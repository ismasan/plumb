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

    # A Stream consumes any enumerable (it checks `#each` at runtime in #call),
    # not another Stream — so it reports Any as its input and opts out of the
    # #>> composition check. This lets a producer of a raw Enumerator/Array (eg.
    # a CSV enumerator) feed a Stream. Covariant Stream[X] <= Stream[Y]
    # subtyping is unaffected (that goes through #subtype_of? / #children).
    # Memoized at the class level (instances are frozen; Types isn't loaded yet
    # when this file is) — #call hits it on every data invocation.
    def self.each_interface = @each_interface ||= Types::Interface[:each]

    def input_type = StreamClass.each_interface

    # The [Step] interface
    # @param result [Result::Valid]
    # @return [Result::Valid, Result::Invalid]
    def call(result)
      result = input_type.call(result)
      return result unless result.valid?
      # return result.invalid(errors: 'is not an Enumerable') unless result.value.respond_to?(:each)

      # Snapshot the source enumerable into a local so the lazy Enumerator closes
      # over IT, not the result cursor. The cursor may be reused/mutated after we
      # return (eg. a Stream nested in an Array, whose cursor is reset per
      # element) — closing over the snapshot keeps each stream bound to its own
      # input regardless.
      source = result.value
      enum = Enumerator.new do |y|
        source.each do |e|
          y << @element_type.resolve(e)
        end
      end

      # Copying #valid (not #valid!): the returned result's value IS the lazy
      # enum, so the result must be a fresh object the caller can hold while its
      # own cursor moves on.
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

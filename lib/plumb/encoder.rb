# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/function'

module Plumb
  # A reversible, type-aware transform between two representations of a value —
  # an input type and an output type. Neither side need be a "wire" format: a
  # serialized string and a parsed Ruby object, or one in-memory data structure
  # and another, are equally valid. Declared class-based, with the types given
  # as a one-pair Hash literal:
  #
  #   DateRange = Types::Range[Types::Date]
  #   JSONDateRange = Types::Hash[from: Types::Date, to: Types::Date]
  #
  #   class JSONDateRangeEncoder < Plumb::Encoder[JSONDateRange => DateRange]
  #     def encode(range) = { from: range.begin, to: range.end }
  #     def decode(hash) = hash[:from]..hash[:to]
  #   end
  #
  # The DEFAULT direction is the declared one (`input => output`, running
  # #decode) — an encoder composes like a normal Function:
  #
  #   JSONDateRange >> JSONDateRangeEncoder >> DateRange   # decode
  #
  # Composed next to a type that matches its OUTPUT side instead, it
  # transparently runs the inverse (#encode, input/output swapped):
  #
  #   DateRange >> JSONDateRangeEncoder >> JSONDateRange   # encode
  #
  # When the context gives no signal (schema literals, `#/`, `.parse`, an
  # opaque/Any neighbour) the default direction is used; `.decoding` /
  # `.encoding` are the explicit escape hatches. Each direction is a plain
  # {Function} whose proc runs the encoder's method — so subtyping, `#>>`
  # composition checks and reductions, visitors and the JSON Schema all work
  # on it with no encoder-specific machinery.
  class Encoder
    # Build the parameterized superclass: `Encoder[Input => Output]`.
    # The pair is a one-pair Hash literal; both sides are wrapped as Plumb
    # types (a raw Hash becomes a HashClass, so
    # `Encoder[{from: Date} => DateRange]` works).
    #
    # @param pair [Hash] a one-pair Hash: input type => output type
    # @return [Class]
    def self.[](pair)
      unless pair.is_a?(::Hash) && pair.size == 1
        raise ArgumentError,
              "#{self}[Input => Output] expects a one-pair Hash (eg. Encoder[Types::String => Types::Date]), " \
              "got #{pair.inspect}"
      end

      input, output = pair.first
      input = Composable.wrap(input)
      output = Composable.wrap(output)
      # Singleton methods (unlike class ivars) are inherited by the user's
      # subclass, so `class Foo < Encoder[A => B]` gets .input_type/.output_type.
      Class.new(self) do
        define_singleton_method(:input_type) { input }
        define_singleton_method(:output_type) { output }
      end
    end

    class << self
      def input_type
        raise ArgumentError,
              "#{inspect} declares no types; define it as `class #{inspect} < Plumb::Encoder[Input => Output]`"
      end

      alias output_type input_type

      # The input type to rewrite for a particular matched output type.
      # Fixed for a normal encoder — the declared input type, regardless of what
      # matched. A GENERIC encoder (one whose output_type is a container top like
      # Types::Range, matching any Range[member]) overrides this to BUILD its input
      # from the matched node's structure, so `Range[Date]` yields a
      # `from: Date, to: Date` input and `Range[Integer]` a `from: Integer, …` one.
      # The codec then rewrites that member type through itself as usual. Mirrors
      # how the Rewriter reads an Array's element type off the matched node.
      # @param matched_type [Composable] the type this encoder matched
      # @return [Composable]
      def input_type_for(_matched_type) = input_type

      # The default step: the declared `input_type -> output_type` direction,
      # running #decode. A plain Function — #call validates the input type,
      # runs the encoder's method, and validates the produced value against
      # the output type (a wrong return value becomes an invalid Result, not
      # silent corruption); subtyping identity, accepted type and `#>>` checks
      # all come with Function. Memoized per subclass (steps are frozen).
      # @return [Function]
      def decoding
        @decoding ||= build_step(:decode, input_type, output_type)
      end

      # The inverse step: `output_type -> input_type`, running #encode.
      # @return [Function]
      def encoding
        @encoding ||= build_step(:encode, output_type, input_type)
      end

      # A direction step with one or both sides substituted — used by
      # Codec::Rewriter to splice in a rewritten input type or a narrowed
      # output type, keeping each rewritten field a single Function node.
      #
      # The substitutions name the ENCODER's declared sides, not the step's
      # positions, so the caller doesn't have to transpose them per direction:
      # `input_side` always replaces the declared input, `output_side` the
      # declared output, whichever end of the step each lands on.
      # @return [Function]
      def step(direction, input_side: nil, output_side: nil)
        base = direction == :decode ? decoding : encoding
        return base unless input_side || output_side

        in_t, out_t = direction == :decode ? [input_side, output_side] : [output_side, input_side]
        Function.new(in_t || base.input_type, out_t || base.output_type, base.fn)
      end

      # Composition-context direction pick when the encoder is the RIGHT
      # operand (see Composable#to_plumb_type). For `left >> Enc`, orient by
      # what `left` produces; for a union/intersection, branches describe the
      # same produced value, so orient by what the sibling produces relative to
      # what each direction produces. Falls back to the default direction —
      # the ordinary composition check raises if it genuinely doesn't fit.
      def to_plumb_type(op:, left:)
        produced = Plumb::Subtyping.resolved_output(Composable.wrap(left))
        # `left >> Enc` feeds `left`'s output into the step; in a union/
        # intersection the branches describe the same produced value.
        pick_direction(produced, op == :>> ? :consumes : :produces)
      end

      # Left-position composition (`Enc >> X`, `Enc | X`, ...): a Class has no
      # Composable operators, so these singleton versions orient against the
      # right operand and delegate to the oriented step.
      def >>(other) = oriented_against(other, :>>) >> other
      def |(other) = oriented_against(other, :|) | other
      def &(other) = oriented_against(other, :&) & other

      def /(other) = decoding / other

      # Direct use runs the default direction — also the Composable.wrap hook
      # for context-free positions (schema literals, `Array[Enc]`, `#/`).
      def to_composable = decoding
      def call(result) = decoding.call(result)
      def resolve(...) = decoding.resolve(...)
      def parse(...) = decoding.parse(...)

      # Value-level conveniences for each direction.
      def encode(value) = encoding.parse(value)
      def decode(value) = decoding.parse(value)

      private

      # Build one direction as a plain Function. The transform proc wraps the
      # encoder's method: exceptions raised inside #encode/#decode become
      # invalid Results.
      def build_step(direction, in_type, out_type)
        if instance_method(direction).owner == Encoder
          raise ArgumentError, "#{inspect} must implement ##{direction} to be used in this direction"
        end

        run = new.freeze.method(direction)
        encoder_class = self
        step_proc = lambda do |result|
          result.valid!(run.call(result.value))
        rescue StandardError => e
          result.invalid!(errors: "#{encoder_class.inspect}##{direction} failed: #{e.message}")
        end
        Function.new(in_type, out_type, step_proc)
      end

      # Orientation for the LEFT-position operators above, where the encoder
      # must PRODUCE something the sibling fits: for `>>` the sibling consumes
      # what we produce, so orient by what it ACCEPTS; in a union/intersection
      # both sides describe the same resulting value, so orient by what it
      # produces.
      def oriented_against(other, op)
        other = Composable.wrap(other)
        produced = op == :>> ? Plumb::Subtyping.accepted_type(other) : Plumb::Subtyping.resolved_output(other)
        pick_direction(produced, :produces)
      end

      # Pick a direction by matching `candidate` against the two declared sides.
      # `orient` says which relation `candidate` stands in to this encoder:
      #   :consumes — it is fed INTO the step (a `>>` neighbour's output), so it
      #               must match the side the step reads;
      #   :produces — it is what the step must yield (a union sibling's value,
      #               or a `>>` right side's accepted input).
      # Decode (the declared direction) wins ties and is the fallback: encode is
      # chosen only when it is the unambiguous fit, so an ambiguous, opaque or
      # unmatched candidate keeps the declared direction and the ordinary
      # composition check reports it if it genuinely doesn't fit.
      def pick_direction(candidate, orient)
        decode_side, encode_side = orient == :consumes ? [input_type, output_type] : [output_type, input_type]
        return encoding if Plumb::Subtyping.subtype?(candidate, encode_side) &&
                           !Plumb::Subtyping.subtype?(candidate, decode_side)

        decoding
      end
    end

    # The value-level contract. These are also the sentinels build_step checks
    # (`instance_method(direction).owner == Encoder`), so using an encoder in a
    # direction it doesn't implement fails at BUILD time with a better message
    # than these — which is why they stay deliberately plain.
    def encode(_value) = raise(NotImplementedError, "#{self.class} must implement #encode(value)")
    def decode(_value) = raise(NotImplementedError, "#{self.class} must implement #decode(value)")
  end
end

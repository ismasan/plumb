# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/function'

module Plumb
  # A reversible, type-aware transform between two representations of a value —
  # typically a wire/serialized form and an internal Ruby form. Declared
  # class-based, with the types given as a one-pair Hash literal:
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
  # `.encoding` are the explicit escape hatches. Each direction is an
  # {Encoder::Step} — a Function subclass — so subtyping, `#>>` composition
  # checks and reductions, visitors and the JSON Schema all work on it as on
  # any Function.
  class Encoder
    # Build the parameterized superclass: `Encoder[Input => Output]`.
    # The pair is a one-pair Hash literal; both sides are wrapped as Plumb
    # types (a raw Hash becomes a HashClass, so
    # `Encoder[{from: Date} => DateRange]` works).
    #
    # @param pair [Hash] a one-pair Hash: input (wire) type => output (internal) type
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

      # A noop encoder passes values through untouched — used by Codec to
      # declare pass-through types (see Codec.noop). Real encoders are not.
      def noop? = false

      # The default step: the declared `input_type -> output_type` direction,
      # running #decode. Memoized per subclass (steps are frozen).
      # @return [Encoder::Step]
      def decoding
        @decoding ||= Step.new(self, :decode)
      end

      # The inverse step: `output_type -> input_type`, running #encode.
      # @return [Encoder::Step]
      def encoding
        @encoding ||= Step.new(self, :encode)
      end

      # Composition-context direction pick when the encoder is the RIGHT
      # operand (see Composable#to_plumb_type). For `left >> Enc`, orient by
      # what `left` produces; for a union/intersection, branches describe the
      # same produced value, so orient by what the sibling produces relative to
      # what each direction produces. Falls back to the default direction —
      # the ordinary composition check raises if it genuinely doesn't fit.
      def to_plumb_type(op:, left:)
        produced = Plumb::Subtyping.resolved_output(Composable.wrap(left))
        case op
        when :>>
          pick_direction(consumes: produced)
        else # :|, :&
          pick_direction(produces: produced)
        end
      end

      # Left-position composition (`Enc >> X`, `Enc | X`, ...): a Class has no
      # Composable operators, so these singleton versions orient against the
      # right operand and delegate to the oriented step.
      def >>(other)
        step = pick_direction(produces: Plumb::Subtyping.accepted_type(Composable.wrap(other)))
        step >> other
      end

      def |(other)
        union_oriented(other) | other
      end

      def &(other)
        union_oriented(other) & other
      end

      def /(other) = decoding / other

      # Direct use runs the default direction.
      def call(result) = decoding.call(result)
      def resolve(...) = decoding.resolve(...)
      def parse(...) = decoding.parse(...)

      # Value-level conveniences for each direction.
      def encode(value) = encoding.parse(value)
      def decode(value) = decoding.parse(value)

      private

      # In a union/intersection the sibling and the encoder describe the same
      # RESULTING value, so orient by produced types.
      def union_oriented(other)
        pick_direction(produces: Plumb::Subtyping.resolved_output(Composable.wrap(other)))
      end

      # Both directions, keyed either by what the step must CONSUME (a `>>`
      # neighbour's output feeding it) or by what it must PRODUCE (a union
      # sibling's produced value, or a `>>` right side's accepted input).
      #   consumes ⊆ input_type  -> decoding;  consumes ⊆ output_type -> encoding
      #   produces ⊆ output_type -> decoding;  produces ⊆ input_type  -> encoding
      # Anything else (ambiguous — resolves to the first branch — opaque, or
      # no match) falls back to the default direction.
      def pick_direction(consumes: nil, produces: nil)
        first, second = consumes ? [input_type, output_type] : [output_type, input_type]
        candidate = consumes || produces
        return decoding if Plumb::Subtyping.subtype?(candidate, first)
        return encoding if Plumb::Subtyping.subtype?(candidate, second)

        decoding
      end
    end

    # The value-level contract. Subclasses implement both; a Step for a
    # direction whose method is missing raises at build time.
    def encode(_value)
      raise NotImplementedError, "#{self.class} must implement #encode(value) (#{self.class.output_type.inspect} -> #{self.class.input_type.inspect})"
    end

    def decode(_value)
      raise NotImplementedError, "#{self.class} must implement #decode(value) (#{self.class.input_type.inspect} -> #{self.class.output_type.inspect})"
    end

    # One direction of an Encoder, as a composable node. A Function subclass:
    # #call validates the input type, runs the encoder's #encode/#decode, and
    # validates the produced value against the output type — so a wrong return
    # value becomes an invalid Result, not silent corruption. Subtyping
    # identity, accepted type and `#>>` checks all come from Function.
    #
    # `input_type:`/`output_type:` overrides substitute a side (used by Codec
    # to splice a rewritten wire type or a narrowed field type in, and by the
    # Decorator to rebuild with decorated children).
    class Step < Function
      attr_reader :encoder_class, :direction

      # @param encoder_class [Class] an Encoder subclass
      # @param direction [Symbol] :decode (the declared direction) or :encode
      def initialize(encoder_class, direction, input_type: nil, output_type: nil)
        # Set these before super — Function#initialize freezes the node.
        @encoder_class = encoder_class
        @direction = direction
        # Resolve the declared types first: an unparameterized encoder gets the
        # "declares no types" error before the missing-method one.
        default_in, default_out = direction == :decode ? [encoder_class.input_type, encoder_class.output_type] : [encoder_class.output_type, encoder_class.input_type]
        if encoder_class.instance_method(direction).owner == Encoder
          raise ArgumentError, "#{encoder_class.inspect} must implement ##{direction} to be used in this direction"
        end

        instance = encoder_class.new.freeze
        step_proc = lambda do |result|
          result.valid!(instance.public_send(direction, result.value))
        rescue StandardError => e
          result.invalid!(errors: "#{encoder_class.inspect}##{direction} failed: #{e.message}")
        end
        super(input_type || default_in, output_type || default_out, step_proc)
      end

      # Naming would otherwise derive :function from the superclass.
      def node_name = :encoder

      def ==(other)
        other.is_a?(Step) &&
          other.encoder_class == encoder_class &&
          other.direction == direction &&
          other.children == children
      end

      # Like Function's `(In -> Out)`, prefixed with the encoder class — the
      # direction is implicit in the order of the types.
      private def _inspect
        "#{encoder_class.inspect}(#{input_type.inspect} -> #{output_type.inspect})"
      end
    end
  end
end

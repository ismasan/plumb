# frozen_string_literal: true

require 'spec_helper'

module EncoderSpecTypes
  DateRange = Types::Range[Types::Date]
  JSONDateRange = Types::Hash[from: Types::Date, to: Types::Date]

  class DateRangeEncoder < Plumb::Encoder[JSONDateRange => DateRange]
    def encode(range) = { from: range.begin, to: range.end }
    def decode(hash) = hash[:from]..hash[:to]
  end

  class ISODateEncoder < Plumb::Encoder[Types::String => Types::Date]
    def encode(date) = date.iso8601
    def decode(str) = ::Date.parse(str)
  end

  class StringNoopEncoder < Plumb::Encoder[Types::String => Types::String]
    def encode(value) = value
    def decode(value) = value
  end

  class DecodeOnlyEncoder < Plumb::Encoder[Types::String => Types::Date]
    def decode(str) = ::Date.parse(str)
  end

  class BrokenEncoder < Plumb::Encoder[Types::String => Types::Date]
    def encode(_date) = raise 'kaboom'
    def decode(_str) = 42 # not a Date: output check must catch it
  end

  DATE = ::Date.new(2024, 1, 1)
  RANGE = ::Date.new(2024, 1, 1)..::Date.new(2024, 2, 1)
  ENCODED_RANGE = { from: ::Date.new(2024, 1, 1), to: ::Date.new(2024, 2, 1) }.freeze

  RSpec.describe Plumb::Encoder do
    describe '.[] class builder' do
      it 'expects a one-pair Hash' do
        expect { Plumb::Encoder[Types::String] }.to raise_error(ArgumentError, /one-pair Hash/)
        expect { Plumb::Encoder[{ Types::String => Types::Date, Types::Integer => Types::Float }] }
          .to raise_error(ArgumentError, /one-pair Hash/)
      end

      it 'wraps both sides as Plumb types (a raw Hash becomes a Hash schema)' do
        klass = Plumb::Encoder[{ from: Types::Date, to: Types::Date } => DateRange]
        expect(klass.input_type).to be_a(Plumb::HashClass)
        expect(klass.output_type).to eq(DateRange)
      end

      it 'exposes the declared types on subclasses' do
        expect(ISODateEncoder.input_type).to eq(Types::String)
        expect(ISODateEncoder.output_type).to eq(Types::Date)
      end

      it 'raises for an unparameterized encoder' do
        expect { Class.new(Plumb::Encoder).decoding }.to raise_error(ArgumentError, /declares no types/)
      end

      it 'raises when the used direction is not implemented' do
        expect(DecodeOnlyEncoder.decode('2024-01-01')).to eq(DATE)
        expect { DecodeOnlyEncoder.encoding }.to raise_error(ArgumentError, /must implement #encode/)
      end
    end

    describe '.decoding / .encoding steps' do
      it 'decoding is the declared direction, as a plain Function' do
        step = ISODateEncoder.decoding
        expect(step).to be_a(Plumb::Function)
        expect(step.input_type).to eq(Types::String)
        expect(step.output_type).to eq(Types::Date)
        assert_result(step.resolve('2024-01-01'), DATE, true)
      end

      it 'encoding is the inverse, with input/output swapped' do
        step = ISODateEncoder.encoding
        expect(step.input_type).to eq(Types::Date)
        expect(step.output_type).to eq(Types::String)
        assert_result(step.resolve(DATE), '2024-01-01', true)
      end

      it 'subtypes by what each direction produces' do
        expect(ISODateEncoder.decoding <= Types::Date).to be(true)
        expect(ISODateEncoder.encoding <= Types::String).to be(true)
        expect(ISODateEncoder.decoding <= Types::String).to be(false)
      end

      specify 'Function structural equality applies (directions differ by type order)' do
        expect(ISODateEncoder.decoding).not_to eq(ISODateEncoder.encoding)
        expect(ISODateEncoder.decoding).not_to eq(StringNoopEncoder.decoding)
      end
    end

    describe 'direction inference in compositions' do
      it 'runs the declared direction after a type matching its input' do
        pipeline = JSONDateRange >> DateRangeEncoder >> DateRange
        expect(pipeline.parse(ENCODED_RANGE)).to eq(RANGE)
      end

      it 'runs the inverse after a type matching its output' do
        pipeline = DateRange >> DateRangeEncoder >> JSONDateRange
        expect(pipeline.parse(RANGE)).to eq(ENCODED_RANGE)
      end

      it 'orients by what the right side accepts when the encoder is on the left' do
        expect((DateRangeEncoder >> DateRange).parse(ENCODED_RANGE)).to eq(RANGE)
        expect((DateRangeEncoder >> JSONDateRange).parse(RANGE)).to eq(ENCODED_RANGE)
      end

      it 'orients when a Hash schema is intersected with an encoder (not context-free to Never)' do
        # HashClass#& must route the encoder through the orientation hook; a
        # context-free wrap would default to decode and collapse to Never.
        result = JSONDateRange & DateRangeEncoder
        expect(result).not_to be_a(Plumb::NeverClass)
      end

      it 'orients unions by the produced value' do
        # The lenient-union pattern: accept a Date, or decode a string into one.
        union = Types::Date | ISODateEncoder
        expect(union.parse(DATE)).to eq(DATE)
        expect(union.parse('2024-01-01')).to eq(DATE)

        union = ISODateEncoder | Types::Date
        expect(union.parse('2024-01-01')).to eq(DATE)
      end

      it 'reduces a trailing re-assertion of the produced type' do
        expect(JSONDateRange >> DateRangeEncoder >> DateRange)
          .to eq(JSONDateRange >> DateRangeEncoder)
      end

      it 'raises the ordinary composition error for an unrelated neighbour' do
        expect { Types::Symbol >> ISODateEncoder }.to raise_error(Plumb::TypeError, /is not a subtype of/)
      end
    end

    describe 'default-direction fallbacks (no orientation context)' do
      it 'falls back to the declared direction for a self-inverse encoder' do
        expect((Types::String >> StringNoopEncoder).parse('hi')).to eq('hi')
      end

      it 'falls back to the declared direction after Any' do
        expect((Types::Any >> ISODateEncoder).parse('2024-01-01')).to eq(DATE)
      end

      it 'uses the declared direction in schema literals' do
        schema = Types::Hash[date: ISODateEncoder]
        expect(schema.parse({ date: '2024-01-01' })).to eq({ date: DATE })
        expect(Types::Array[ISODateEncoder].parse(['2024-01-01'])).to eq([DATE])
      end

      it 'uses the declared direction with #/' do
        expect((Types::String / ISODateEncoder).parse('2024-01-01')).to eq(DATE)
      end

      it 'parses directly in the declared direction' do
        expect(ISODateEncoder.parse('2024-01-01')).to eq(DATE)
        assert_result(ISODateEncoder.resolve(10), 10, false)
      end
    end

    describe 'runtime behaviour' do
      it 'validates the input side' do
        assert_result(ISODateEncoder.decoding.resolve(42), 42, false)
        assert_result(ISODateEncoder.encoding.resolve('nope'), 'nope', false)
      end

      it 'turns an exception in the user method into an invalid Result' do
        result = BrokenEncoder.encoding.resolve(DATE)
        expect(result.valid?).to be(false)
        expect(result.errors).to match(/#encode failed: kaboom/)
      end

      it 'validates the returned value against the declared output type' do
        result = BrokenEncoder.decoding.resolve('2024-01-01')
        expect(result.valid?).to be(false)
      end

      it 'round-trips' do
        expect(ISODateEncoder.decode(ISODateEncoder.encode(DATE))).to eq(DATE)
        expect(DateRangeEncoder.encode(DateRangeEncoder.decode(ENCODED_RANGE))).to eq(ENCODED_RANGE)
      end
    end

    describe 'Decorator support' do
      it 'rebuilds a Step preserving encoder class and direction' do
        pipeline = JSONDateRange >> DateRangeEncoder
        decorated = Plumb.decorate(pipeline) { |t| t }
        expect(decorated).to eq(pipeline)
        expect(decorated.parse(ENCODED_RANGE)).to eq(RANGE)
      end
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'

module CodecFormsSpec
  Codec = Plumb::Codec::Forms

  RSpec.describe Plumb::Codec::Forms do
    describe 'numerics (strict string patterns)' do
      specify Types::Integer do
        decoder, encoder = Codec.for(Types::Integer)
        expect(decoder.parse('80')).to eq(80)
        expect(decoder.parse('-3')).to eq(-3)
        expect(decoder.resolve('12abc').valid?).to be(false)
        expect(decoder.resolve('1,000').valid?).to be(false)
        expect(decoder.resolve(80).valid?).to be(false) # strictly stringy wire
        expect(encoder.parse(80)).to eq('80')
      end

      specify Types::Float do
        decoder, encoder = Codec.for(Types::Float)
        expect(decoder.parse('10.5')).to eq(10.5)
        expect(encoder.parse(10.5)).to eq('10.5')
      end

      specify Types::Decimal do
        decoder, encoder = Codec.for(Types::Decimal)
        expect(decoder.parse('10.5')).to eq(BigDecimal('10.5'))
        expect(encoder.parse(BigDecimal('10.5'))).to eq('10.5')
      end

      specify 'a Numeric field decodes to Integer or Float by shape' do
        decoder, encoder = Codec.for(Types::Numeric)
        expect(decoder.parse('10')).to eq(10)
        expect(decoder.parse('10.5')).to eq(10.5)
        expect(encoder.parse(BigDecimal('10.5'))).to eq('10.5')
      end
    end

    describe 'booleans' do
      specify Types::Boolean do
        decoder, encoder = Codec.for(Types::Boolean)
        expect(decoder.parse('true')).to be(true)
        expect(decoder.parse('TRUE')).to be(true)
        expect(decoder.parse('1')).to be(true)
        expect(decoder.parse('false')).to be(false)
        expect(decoder.parse('0')).to be(false)
        expect(decoder.resolve('nope').valid?).to be(false)
        expect(decoder.resolve(1).valid?).to be(false) # integers are not stringy
        expect(encoder.parse(true)).to eq('true')
        expect(encoder.parse(false)).to eq('false')
      end
    end

    describe 'nil (empty form field)' do
      specify 'a nullable field decodes the empty string to nil' do
        decoder, encoder = Codec.for(Types::Date | Types::Nil)
        expect(decoder.parse('')).to be_nil
        expect(decoder.parse('2024-01-30')).to eq(::Date.new(2024, 1, 30))
        expect(encoder.parse(nil)).to eq('')
      end
    end

    describe 'dates and times' do
      specify Types::Date do
        decoder, encoder = Codec.for(Types::Date)
        expect(decoder.parse('2024-01-30')).to eq(::Date.new(2024, 1, 30))
        expect(decoder.resolve('2024-').valid?).to be(false)
        expect(encoder.parse(::Date.new(2024, 1, 30))).to eq('2024-01-30')
      end

      specify Types::Time do
        time = ::Time.parse('2024-08-30T20:15:23Z')
        decoder, encoder = Codec.for(Types::Time)
        expect(decoder.parse('2024-08-30T20:15:23Z')).to eq(time)
        expect(decoder.resolve('2024-').valid?).to be(false)
        expect(encoder.parse(time)).to eq('2024-08-30T20:15:23Z')
      end
    end

    describe 'URIs' do
      let(:http_str) { 'http://foo.bar' }
      let(:file_str) { 'file:///foo/bar' }

      specify Types::URI::Generic do
        decoder, encoder = Codec.for(Types::URI::Generic)
        expect(decoder.parse(http_str)).to eq(URI.parse(http_str))
        expect(decoder.parse(file_str)).to eq(URI.parse(file_str))
        expect(decoder.resolve('no scheme').valid?).to be(false)
        expect(encoder.parse(URI.parse(http_str))).to eq(http_str)
      end

      specify 'narrower URI fields pick the most specific encoder' do
        decoder, = Codec.for(Types::URI::HTTP)
        expect(decoder.parse(http_str)).to eq(URI.parse(http_str))
        expect(decoder.resolve(file_str).valid?).to be(false)

        decoder, = Codec.for(Types::URI::File)
        expect(decoder.parse(file_str)).to eq(URI.parse(file_str))
        expect(decoder.resolve(http_str).valid?).to be(false)
      end
    end

    describe 'whole schemas' do
      specify 'decodes and re-encodes form params against an internal schema' do
        config = Types::Hash[
          host: Types::URI::HTTP,
          port: Types::Integer,
          active: Types::Boolean,
          starts_on: Types::Date | Types::Nil,
          tags: Types::Array[Types::String]
        ]
        params = { host: 'http://example.com', port: '80', active: '1', starts_on: '', tags: %w[a b] }
        decoder, encoder = Codec.for(config)
        decoded = decoder.parse(params)
        expect(decoded).to eq(
          host: URI.parse('http://example.com'), port: 80, active: true, starts_on: nil, tags: %w[a b]
        )
        expect(encoder.parse(decoded)).to eq(
          host: 'http://example.com', port: '80', active: 'true', starts_on: '', tags: %w[a b]
        )
      end

      specify 'JSON Schema describes the stringly wire format' do
        schema = Plumb::JSONSchemaVisitor.call(Codec >> Types::Hash[port: Types::Integer, on: Types::Date])
        expect(schema.dig('properties', 'port', 'type')).to eq('string')
        expect(schema.dig('properties', 'on')).to eq('type' => 'string', 'format' => 'date')
      end
    end
  end
end

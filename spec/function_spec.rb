# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb::Function do
  describe '.[]' do
    specify 'input => output with a block' do
      type = Plumb::Function[String => Integer] { |result| result.valid(result.value.size) }

      expect(type).to be_a(described_class)
      expect(type.input_type).to eq(Types::String)
      expect(type.output_type).to eq(Types::Integer)
      assert_result(type.resolve('abc'), 3, true)
    end

    specify 'input => output with a callable' do
      callable = ->(result) { result.valid(result.value.size) }
      type = Plumb::Function[callable, String => Integer]

      expect(type).to be_a(described_class)
      assert_result(type.resolve('abc'), 3, true)
    end

    it 'validates both ends of the function' do
      type = Plumb::Function[String => Integer] { |result| result.valid(result.value.to_s) }

      assert_result(type.resolve(10), 10, false)
      assert_result(type.resolve('abc'), 'abc', false)
    end

    it 'wraps Composable types as well as Ruby classes' do
      type = Plumb::Function[Types::String => Types::Integer] { |result| result.valid(result.value.size) }

      assert_result(type.resolve('abcd'), 4, true)
    end

    it 'composes with other steps' do
      type = Types::String \
        >> Plumb::Function[String => Integer] { |r| r.valid(r.value.size) } \
        >> Plumb::Function[Integer => String] { |r| r.valid("size: #{r.value}") }

      assert_result(type.resolve('abc'), 'size: 3', true)
      assert_result(type.resolve(10), 10, false)
    end

    describe 'identity' do
      it 'returns the type itself when input and output match and there is nothing to apply' do
        expect(Plumb::Function[String => String]).to eq(Types::String)
      end

      it 'returns Types::Any with no arguments' do
        expect(Plumb::Function[]).to eq(Types::Any)
        expect(Plumb::Function[{}]).to eq(Types::Any)
      end

      it 'still builds a Function when a callable is given' do
        type = Plumb::Function[String => String] { |result| result.valid(result.value.upcase) }

        expect(type).to be_a(described_class)
        assert_result(type.resolve('abc'), 'ABC', true)
      end
    end

    specify 'a callable with no types' do
      type = Plumb::Function[->(result) { result.valid(result.value * 2) }]

      expect(type.input_type).to eq(Types::Any)
      expect(type.output_type).to eq(Types::Any)
      assert_result(type.resolve(2), 4, true)
    end

    specify 'a block with no types' do
      type = Plumb::Function[] { |result| result.valid(result.value * 2) }

      assert_result(type.resolve(2), 4, true)
      assert_result(type.resolve('ab'), 'abab', true)
    end

    describe 'argument errors' do
      it 'raises when types differ but no callable is given' do
        expect { Plumb::Function[String => Integer] }.to raise_error(ArgumentError, /no explicit transform/)
      end

      it 'raises when given more than one input => output pair' do
        expect { Plumb::Function[{ String => Integer, Integer => String }] }
          .to raise_error(ArgumentError, /single key/)
      end

      it 'raises when given both a callable and a block' do
        callable = ->(result) { result.valid(1) }

        expect { Plumb::Function[callable] { |r| r.valid(2) } }
          .to raise_error(ArgumentError, /not both/)
        expect { Plumb::Function[callable, { String => Integer }] { |r| r.valid(2) } }
          .to raise_error(ArgumentError, /not both/)
      end

      it 'raises when given arguments it cannot interpret' do
        expect { Plumb::Function[42] }.to raise_error(ArgumentError, /expected Plumb/)
        expect { Plumb::Function[String] }.to raise_error(ArgumentError, /expected Plumb/)
        expect { Plumb::Function[{ String => Integer }, 42] }.to raise_error(ArgumentError, /expected Plumb/)
      end
    end
  end
end

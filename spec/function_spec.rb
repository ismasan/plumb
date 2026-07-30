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

  # A Function's #children is only [input_type, output_type], so the default
  # Composable#== called any two same-typed conversions equal regardless of what
  # they compute — and any two OPAQUE functions equal regardless of their callable,
  # since both ends are Any. Reducers that read #== as node identity then dropped
  # one of the pair. #== compares #identity instead.
  describe '#==' do
    it 'distinguishes two opaque functions wrapping different callables' do
      a = Plumb::Composable.wrap(->(result) { result })
      b = Plumb::Composable.wrap(->(result) { result })

      expect(a == b).to be(false)
      expect(a == a).to be(true)
    end

    it 'distinguishes two conversions that declare the same types but differ' do
      to_i = Types::String.transform(::Integer, &:to_i)
      size = Types::String.transform(::Integer) { |v| v.size }

      expect(to_i.input_type).to eq(size.input_type)   # same declared ends...
      expect(to_i.output_type).to eq(size.output_type)
      expect(to_i == size).to be(false)                # ...but not the same step
    end

    # Compared on #identity (the caller's own callable, or a deterministic token
    # the builder chose) rather than #fn, which #transform rebuilds per call — so
    # two identical constructions, and the schemas containing them, stay #==.
    describe 'two identical constructions remain equal' do
      {
        'transform with a coercion symbol' => -> { Types::String.transform(:to_sym) },
        'transform with &:sym' => -> { Types::String.transform(::Integer, &:to_i) },
        'transform with an explicit output + symbol' => -> { Types::String.transform(::Numeric, :to_f) },
        'build with a factory method' => -> { Types::String.build(::Date, :parse) },
        'invoke' => -> { Types::String.invoke(:downcase) },
        'invoke with args' => -> { Types::Array.invoke(:[], 1) },
        'a chain that fuses' => lambda {
          Types::String.transform(::Integer, &:to_i) >> Types::Integer.transform(::Float, &:to_f)
        },
        'a record containing conversions' => lambda {
          Types::Hash[age: Types::Lax::Integer, name: Types::String.invoke(:strip)]
        }
      }.each do |label, build|
        it label do
          expect(build.call).to eq(build.call)
        end
      end
    end

    it 'keeps a decorated-but-unchanged node equal to the original' do
      type = Types::String.build(::Date, :parse)
      expect(Plumb.decorate(type) { |node| node }).to eq(type)
    end

    # An anonymous block is the whole behaviour of the step and cannot be proven
    # equivalent to another, so it is compared by identity. #generate exists for
    # values that VARY (Time.now), which makes calling two of them the same type
    # plainly wrong.
    it 'does not equate two anonymous blocks' do
      expect(Types::Integer.generate { 42 }).not_to eq(Types::Integer.generate { 42 })
    end

    it 'does equate two generates sharing one callable object' do
      gen = -> { 42 }
      expect(Types::Integer.generate(gen)).to eq(Types::Integer.generate(gen))
    end
  end
end

# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb::Types do
  describe 'Result' do
    specify '#success and #halt' do
      result = Plumb::Result.wrap(10)
      expect(result.valid?).to be(true)
      expect(result.value).to eq(10)
      result = result.valid(20)
      expect(result.value).to eq(20)
      result = result.invalid(errors: 'nope')
      expect(result.valid?).to be(false)
      expect(result.invalid?).to be(true)
      expect(result.errors).to eq('nope')
    end
  end

  describe 'constraining with #[]' do
    it 'works with any #=== interface' do
      assert_result(Types::Any[String].resolve('hello'), 'hello', true)
      assert_result(Types::Any['hello'].resolve('hello'), 'hello', true)
      assert_result(Types::Any['hello'].resolve('nope'), 'nope', false)
      assert_result(Types::Any[String][/@/].resolve('hello@server.com'), 'hello@server.com', true)
      Types::Any[String][/@/].resolve('hello').tap do |result|
        expect(result.valid?).to be(false)
        expect(result.errors).to eq('Must match /@/')
      end
    end

    it 'resolves metadata[:type] for classes' do
      expect(Types::Any[String].metadata[:type]).to eq(String)
      expect(Types::Any[Float].metadata[:type]).to eq(Float)
    end

    it 'resolves metadata[:type] for Regexes' do
      expect(Types::Any[/\d+/].metadata[:type]).to eq(String)
    end

    it 'resolves metadata[:type] for numeric Range' do
      expect(Types::Any[1..10].metadata[:type]).to eq(Integer)
      expect(Types::Any[..10.4].metadata[:type]).to eq(Float)
    end

    it 'resolves metadata[:type] for string Range' do
      expect(Types::Any['a'..'f'].metadata[:type]).to eq(String)
    end
  end

  specify '#>>' do
    step1 = Plumb::Step.new { |r| r.valid(r.value + 5) }
    step2 = Plumb::Step.new { |r| r.valid(r.value - 2) }
    step3 = Plumb::Step.new { |r| r.invalid }
    step4 = ->(minus) { Plumb::Step.new { |r| r.valid(r.value - minus) } }
    pipeline = Types::Any >> step1 >> step2 >> step3 >> ->(r) { r.valid(r.value + 1) }

    expect(pipeline.resolve(10).valid?).to be(false)
    expect(pipeline.resolve(10).value).to eq(13)
    expect((step1 >> step2 >> step4.call(1)).resolve(10).value).to eq(12)
    expect((step1 >> ->(r) { r.valid(r.value.to_s) }).resolve(10).value).to eq('15')
  end

  specify 'with custom #metadata' do
    klass = Class.new do
      def metadata = { foo: 'bar', type: self.class }
      def call(result) = result
    end
    type = (Types::Any >> klass.new) | Types::String
    expect(type.metadata).to eq(foo: 'bar', type: [klass, ::String])
  end

  describe '#transform' do
    it 'transforms values' do
      to_i = Types::Any.transform(::Integer, &:to_i)
      plus_ten = Types::Any.transform(::Integer) { |value| value + 10 }
      pipeline = to_i >> plus_ten
      expect(pipeline.resolve('5').value).to eq(15)
    end

    it 'is a noop without a block' do
      to_i = Types::Any.transform(::Integer)
      assert_result(to_i.resolve(10), 10, true)
    end

    it 'sets type in #metadata' do
      to_i = Types::String.transform(::Integer, &:to_i)
      expect(to_i.metadata[:type]).to eq(Integer)
    end
  end

  specify '#as_node' do
    type = Types::String.as_node(:custom_node_name)
    expect(type.node_name).to eq(:custom_node_name)
    expect(type.metadata[:type]).to eq(String)
    with_meta = type.metadata(foo: 1)
    expect(with_meta.metadata[:foo]).to eq(1)
  end

  describe '#invoke' do
    it 'invokes methods on values' do
      expect(Types::String.invoke(:to_i).parse('100')).to eq(100)
      expect(Types::Hash.invoke(:except, :foo).parse(foo: 1, bar: 2)).to eq(bar: 2)
      expect(Types::Array.invoke(:filter, &:even?).parse((0..10).to_a)).to eq([0, 2, 4, 6, 8, 10])
    end

    it 'can call an array of methods' do
      expect(Types::String.invoke(%i[downcase to_sym]).parse('FOO')).to eq(:foo)
    end
  end

  specify Types::Static do
    assert_result(Types::Static['hello'].resolve('hello'), 'hello', true)
    assert_result(Types::Static['hello'].resolve('nope'), 'hello', true)
    expect(Types::Static['hello'].metadata[:type]).to eq(String)
  end

  specify 'Static #==' do
    t1 = Types::Static['hello']
    t2 = Types::Static['hello']
    t3 = Types::Static['bye']
    expect(t1 == t2).to be(true)
    expect(t1 == t3).to be(false)
  end

  specify '#check' do
    is_a_string = Types::Any.check('not a string') { |value| value.is_a?(::String) }
    expect(is_a_string.resolve('yup').valid?).to be(true)
    expect(is_a_string.resolve(10).valid?).to be(false)
    expect(is_a_string.resolve(10).errors).to eq('not a string')
  end

  specify '#present' do
    assert_result(Types::Any.present.resolve, Plumb::Undefined, false)
    assert_result(Types::Any.present.resolve(''), '', false)
    assert_result(Types::Any.present.resolve('foo'), 'foo', true)
    assert_result(Types::Any.present.resolve([]), [], false)
    assert_result(Types::Any.present.resolve([1, 2]), [1, 2], true)
    assert_result(Types::Any.present.resolve(nil), nil, false)
  end

  describe '#[](matcher) using #===' do
    it 'matches value classes' do
      type = Types::Any[::String]
      assert_result(type.resolve('hello'), 'hello', true)
      assert_result(Types::Any[::Integer].resolve('hello'), 'hello', false)
    end

    it 'matches values' do
      type = Types::String['hello']
      assert_result(type.resolve('hello'), 'hello', true)
      assert_result(type.resolve('nope'), 'nope', false)

      type = Types::Lax::String['10']
      assert_result(type.resolve(10), '10', true)
    end

    it 'matches ranges' do
      type = Types::Integer[10..100]
      assert_result(type.resolve(10), 10, true)
      assert_result(type.resolve(99), 99, true)
      assert_result(type.resolve(101), 101, false)
    end

    it 'matches lambdas' do
      type = Types::Integer[->(v) { v.even? }]
      assert_result(type.resolve(10), 10, true)
      assert_result(type.resolve(11), 11, false)
    end

    it 'is aliased as #match' do
      type = Types::Any.match(/^(\([0-9]{3}\))?[0-9]{3}-[0-9]{4}$/)
      expect(type.resolve('(888)555-1212x').valid?).to be(false)
      expect(type.resolve('(888)555-1212').valid?).to be(true)
    end

    specify '#match works for Hash' do
      type = Types::Hash[foo: Types::String].match(->(h) { h[:foo] == 'bar' })
      assert_result(type.resolve(foo: 'bar'), { foo: 'bar' }, true)
      assert_result(type.resolve(foo: 'nope'), { foo: 'nope' }, false)
    end
  end

  specify '#parse' do
    integer = Types::Any[::Integer]
    expect { integer.parse('10') }.to raise_error(Plumb::ParseError)
    expect(integer.parse(10)).to eq(10)
  end

  specify '#|' do
    integer = Types::Any[::Integer]
    string = Types::Any[::String]
    to_s = Types::Any.transform(::Integer, &:to_s)
    title = Types::Any.transform(::Integer) { |v| "The number is #{v}" }

    pipeline = string | (integer >> to_s >> title)

    assert_result(pipeline.resolve('10'), '10', true)
    assert_result(pipeline.resolve(10), 'The number is 10', true)

    pipeline = Types::String | Types::Integer
    failed = pipeline.resolve(10.3)
    expect(failed.errors).to eq(['Must be a String', 'Must be a Integer'])
  end

  specify '#metadata as a setter' do
    to_s = Types::Any.transform(::String, &:to_s).metadata(type: :string)
    to_i = Types::Any.transform(::Integer, &:to_i).metadata(type: :integer).metadata(foo: 'bar')
    pipe = to_s >> to_i
    expect(to_s.metadata[:type]).to eq(:string)
    expect(pipe.metadata[:type]).to eq(:integer)
    expect(pipe.metadata[:foo]).to eq('bar')
  end

  describe '#metadata as a getter' do
    specify 'AND (>>) chains' do
      type = Types::String >> Types::Integer.metadata(foo: 'bar')
      expect(type.metadata).to eq({ type: ::Integer, foo: 'bar' })
    end

    specify 'OR (|) chains' do
      type = Types::String | Types::Integer.metadata(foo: 'bar')
      expect(type.metadata).to eq({ type: [::String, ::Integer], foo: 'bar' })
    end

    specify 'AND (>>) with OR (|)' do
      type = Types::String >> (Types::Integer | Types::Boolean).metadata(foo: 'bar')
      expect(type.metadata).to eq({ type: [::Integer, 'boolean'], foo: 'bar' })

      type = Types::String | (Types::Integer >> Types::Boolean).metadata(foo: 'bar')
      expect(type.metadata).to eq({ type: [::String, 'boolean'], foo: 'bar' })
    end
  end

  specify '#not' do
    string = Types::Any.check('not a string') { |v| v.is_a?(::String) }
    assert_result(Types::Any.not(string).resolve(10), 10, true)
    assert_result(Types::Any.not(string).resolve('hello'), 'hello', false)

    assert_result(string.not.resolve(10), 10, true)

    not_nil = Types::Any.not(nil)
    assert_result(not_nil.resolve(10), 10, true)
    assert_result(not_nil.resolve('aa'), 'aa', true)
    assert_result(not_nil.resolve(nil), nil, false)
  end

  specify 'Types::Not' do
    not_nil = Types::Not[nil]
    assert_result(not_nil.resolve(10), 10, true)
    assert_result(not_nil.resolve('aa'), 'aa', true)
    assert_result(not_nil.resolve(nil), nil, false)
  end

  specify '#invalid' do
    type = Types::Integer[..10].invalid(errors: 'nope')
    assert_result(type.resolve(9), 9, false)
    assert_result(type.resolve(19), 19, true)
    expect(type.resolve(9).errors).to eq('nope')
  end

  specify '#default' do
    assert_result(Types::Any.default('hello').resolve('bye'), 'bye', true)
    assert_result(Types::Any.default('hello').resolve, 'hello', true)
    assert_result(Types::String.default('hello').resolve('bye'), 'bye', true)
    assert_result(Types::String.default('hello').resolve(nil), nil, false)
    assert_result(Types::String.default('hello').resolve(Plumb::Undefined), 'hello', true)
    assert_result(Types::String.default { 'hi' }.resolve(Plumb::Undefined), 'hi', true)
    assert_result(Types::Any.default(nil).resolve, nil, true)
  end

  specify '#nullable' do
    assert_result(Types::String.nullable.resolve('bye'), 'bye', true)
    assert_result(Types::String.resolve(nil), nil, false)
    assert_result(Types::String.nullable.resolve(nil), nil, true)
  end

  specify '#===' do
    expect(Types::String === '1').to be(true)
    expect(Types::String === 1).to be(false)
    expect(Types::String === Types::String).to be(true)
    expect(Types::String === Types::Integer).to be(false)
  end

  specify '#==' do
    expect(Types::String == Types::String).to be(true)
    expect(Types::String[/@/] == Types::String[/@/]).to be(true)
    expect(Types::Array[Types::String] == Types::Array[Types::String]).to be(true)
    expect(Types::String.default('a') == Types::String.default('a')).to be(true)
    expect((Types::String | Types::Integer) == (Types::String | Types::Integer)).to be(true)
    expect(Types::String.default('a') == Types::String.default('b')).to be(false)
  end

  describe '#pipeline' do
    let(:pipeline) do
      Types::Lax::Integer.pipeline do |pl|
        pl.step { |r| r.valid(r.value * 2) }
        pl.step Types::Any.transform(::Integer, &:to_s)
        pl.step { |r| r.valid('The number is %s' % r.value) }
      end
    end

    specify '#metadata' do
      pipe = pipeline.metadata(foo: 'bar')
      expect(pipe.metadata).to include({ type: Integer, foo: 'bar' })
    end

    it 'builds a step composed of many steps' do
      assert_result(pipeline.resolve(2), 'The number is 4', true)
      assert_result(pipeline.resolve('2'), 'The number is 4', true)
      assert_result(pipeline.transform(::String) { |v| v + '!!' }.resolve(2), 'The number is 4!!', true)
      assert_result(pipeline.resolve('nope'), 'nope', false)
    end

    it 'is a Composable and can be further composed' do
      expect(pipeline).to be_a(Plumb::Composable)
      pipeline2 = pipeline.pipeline do |pl|
        pl.step { |r| r.valid(r.value + ' the end') }
      end

      assert_result(pipeline2.resolve(2), 'The number is 4 the end', true)
    end

    it 'is chainable' do
      type = Types::Any.transform(::Integer) { |v| v + 5 } >> pipeline
      assert_result(type.resolve(2), 'The number is 14', true)
    end
  end

  specify '#build' do
    custom = Struct.new(:name) do
      def self.build(name)
        new(name)
      end
    end
    assert_result(Types::Any.build(custom).resolve('Ismael'), custom.new('Ismael'), true)
    with_block = Types::Any.build(custom) { |v| custom.new('mr. %s' % v) }
    expect(with_block.resolve('Ismael').value.name).to eq('mr. Ismael')
    with_symbol = Types::Any.build(custom, :build)
    expect(with_symbol.resolve('Ismael').value.name).to eq('Ismael')
    expect(with_symbol.metadata[:type]).to eq(custom)
  end

  describe '#static' do
    it 'returns a static value if argument given' do
      type = Types::Integer.static(10)
      expect(type.parse(10)).to eq(10)
      expect(type.parse(11)).to eq(10)
      expect(type.parse('foo')).to eq(10)
      expect(type.parse).to eq(10)
      expect(type.metadata[:type]).to eq(Integer)
    end

    it 'does not allow inconsistent types' do
      expect do
        Types::Integer.static('nope')
      end.to raise_error(ArgumentError)
    end

    it 'does not check type for Types::Any' do
      ten = Types::Any.static(10)
      expect(ten.parse).to eq(10)
      expect(ten.metadata[:type]).to eq(Integer)
    end
  end

  describe '#generate' do
    it 'lazily evaluates a block' do
      count = 0
      type = Types::Integer.generate { count += 1 }
      expect(type.parse(10)).to eq(1)
      expect(type.parse(100)).to eq(2)
      expect(type.parse).to eq(3)
      expect(type.parse('foo')).to eq(4)
      expect(type.metadata[:type]).to eq(Integer)
    end
  end

  describe '#with' do
    it 'validates properties of the object' do
      assert_result(Types::Array.with(size: 2).resolve([1]), [1], false)
      assert_result(Types::Array.with(size: 2).resolve([1, 2]), [1, 2], true)
      assert_result(Types::String.with(size: 2).resolve('ab'), 'ab', true)
      assert_result(Types::Array.with(size: 1..2).resolve([1, 2]), [1, 2], true)
      assert_result(Types::Array.with(size: 1..2).resolve([1, 2, 3]), [1, 2, 3], false)
    end
  end

  describe '#policy' do
    specify 'registering rule as :name, value' do
      assert_result(Types::Array.policy(:options, [1]).resolve([1]), [1], true)
    end

    specify ':options' do
      assert_result(Types::String.policy(options: %w[a b c]).resolve('b'), 'b', true)
      assert_result(Types::String.policy(options: %w[a b c]).resolve('d'), 'd', false)
    end

    specify ':options with Array' do
      type = Types::Array.options([1, 2, 3])
      assert_result(type.resolve([1, 2]), [1, 2], true)
      assert_result(type.resolve([1, 3, 3]), [1, 3, 3], true)
      assert_result(type.resolve([1, 4, 3]), [1, 4, 3], false)
      expect(type.metadata[:options]).to eq([1, 2, 3])
    end

    specify ':excluded_from' do
      assert_result(Types::String.policy(excluded_from: %w[a b c]).resolve('b'), 'b', false)
      assert_result(Types::String.policy(excluded_from: %w[a b c]).resolve('d'), 'd', true)
    end

    specify ':excluded_from with Array' do
      assert_result(Types::Array.policy(excluded_from: %w[a b c]).resolve(%w[x z b]), %w[x z b], false)
      assert_result(Types::Array.policy(excluded_from: %w[a b c]).resolve(%w[x z y]), %w[x z y], true)
    end

    specify ':respond_to' do
      assert_result(Types::String.policy(respond_to: :strip).resolve('b'), 'b', true)
      assert_result(Types::String.policy(respond_to: %i[strip chomp]).resolve('b'), 'b', true)
      assert_result(Types::String.policy(respond_to: %i[strip nope]).resolve('b'), 'b', false)
      assert_result(Types::String.policy(respond_to: :nope).resolve('b'), 'b', false)
    end

    specify ':split' do
      assert_result(Types::String.policy(:split).resolve('a,  b , c,d'), %w[a b c d], true)
      assert_result(Types::String.policy(split: '.').resolve('a,  b.ss , c,d'), ['a,  b', 'ss , c,d'], true)
      expect(Types::String.policy(:split).metadata[:type]).to eq(Array)
    end

    specify ':rescue' do
      type = Plumb::Step.new do |r|
        raise ArgumentError, 'nope' unless r.value == 10

        r
      end

      rescued = type.policy(:rescue, ArgumentError)
      result = rescued.resolve(10)
      expect(result.valid?).to be(true)

      result = rescued.resolve(11)
      expect(result.valid?).to be(false)
      expect(result.errors).to be('nope')
    end

    specify '#policy with #==' do
      t1 = Types::Array.options([1, 2, 3])
      t2 = Types::Array.options([1, 2, 3])
      t3 = Types::Array.options([1, 4, 3])
      expect(t1 == t2).to be(true)
      expect(t1 == t3).to be(false)
    end
  end

  describe 'built-in types' do
    specify Types::String do
      assert_result(Types::String.resolve('aa'), 'aa', true)
      assert_result(Types::String.resolve(10), 10, false)
    end

    specify Types::Integer do
      assert_result(Types::Integer.resolve(10), 10, true)
      assert_result(Types::Integer.resolve('10'), '10', false)
    end

    specify Types::Decimal do
      assert_result(Types::Decimal.resolve(BigDecimal(10)), BigDecimal(10), true)
      assert_result(Types::Decimal.resolve('10'), '10', false)
    end

    specify Types::True do
      assert_result(Types::True.resolve(true), true, true)
      assert_result(Types::True.resolve(false), false, false)
    end

    specify Types::Boolean do
      assert_result(Types::Boolean.resolve(true), true, true)
      assert_result(Types::Boolean.resolve(false), false, true)
      assert_result(Types::Boolean.resolve('true'), 'true', false)
    end

    describe Types::Value do
      it 'matches exact values using #==' do
        assert_result(Types::Value['hello'].resolve('hello'), 'hello', true)
        assert_result(Types::Value['hello'].resolve('nope'), 'nope', false)
        assert_result(Types::Lax::String.value('10').resolve(10), '10', true)
        assert_result(Types::Lax::String.value('11').resolve(10), '10', false)
        assert_result(Types::Integer[11].resolve(11), 11, true)
        assert_result(Types::Integer[11].resolve(10), 10, false)
        assert_result(Types::Value[11..15].resolve(11..15), (11..15), true)
      end
    end

    specify Types::Interface do
      obj = Data.define(:name, :age) do
        def test(foo, bar = 1, opt: 2)
          [foo, bar, opt]
        end
      end.new(name: 'Ismael', age: 42)

      assert_result(Types::Interface[:name, :age].resolve(obj), obj, true)
      assert_result(Types::Interface[:name, :age, :test].resolve(obj), obj, true)
      assert_result(Types::Interface[:name, :nope, :test].resolve(obj), obj, false)

      expect(Types::Interface[:name, :age].method_names).to eq(%i[name age])
    end

    specify 'Interface#==' do
      t1 = Types::Interface[:name, :age]
      t2 = Types::Interface[:name, :age]
      t3 = Types::Interface[:name, :age, :foo]
      expect(t1 == t2).to be(true)
      expect(t1 == t3).to be(false)
    end

    specify Types::UUID::V4 do
      uuid_v4 = 'fb1c58ab-9fe8-4039-b075-3d990f52910e'
      assert_result(Types::UUID::V4.resolve(uuid_v4), uuid_v4, true)
      assert_result(Types::UUID::V4.resolve("#{uuid_v4}-EEE"), "#{uuid_v4}-EEE", false)
    end

    specify Types::Email do
      assert_result(Types::Email.resolve('joe@email.com'), 'joe@email.com', true)
      assert_result(Types::Email.resolve('joe.bloggs@email.com'), 'joe.bloggs@email.com', true)
      assert_result(Types::Email.resolve('joe.bloggs+one@email.co.uk'), 'joe.bloggs+one@email.co.uk', true)
      assert_result(Types::Email.resolve('joe.bloggs+one@email'), 'joe.bloggs+one@email', true)
      assert_result(Types::Email.resolve('joe.bloggs+oneemail'), 'joe.bloggs+oneemail', false)
    end

    describe 'URI' do
      let(:http_str) { 'http://foo.bar' }
      let(:file_str) { 'file:///foo/bar' }
      let(:http_uri) { URI.parse(http_str) }
      let(:file_uri) { URI.parse(file_str) }

      specify Types::URI::Generic do
        assert_result(Types::URI::Generic.resolve(http_uri), http_uri, true)
        assert_result(Types::URI::Generic.resolve(file_uri), file_uri, true)
        assert_result(Types::URI::Generic.resolve(19), 19, false)
      end

      specify Types::URI::HTTP do
        assert_result(Types::URI::HTTP.resolve(http_uri), http_uri, true)
        assert_result(Types::URI::HTTP.resolve(file_uri), file_uri, false)
        assert_result(Types::URI::HTTP.resolve(19), 19, false)
      end

      specify Types::URI::File do
        assert_result(Types::URI::File.resolve(http_uri), http_uri, false)
        assert_result(Types::URI::File.resolve(file_uri), file_uri, true)
        assert_result(Types::URI::File.resolve(19), 19, false)
      end

      describe 'Forms::URI' do
        specify Types::Forms::URI::Generic do
          assert_result(Types::Forms::URI::Generic.resolve(http_uri), http_uri, true)
          assert_result(Types::Forms::URI::Generic.resolve(file_uri), file_uri, true)
          assert_result(Types::Forms::URI::Generic.resolve(http_str), http_uri, true)
          assert_result(Types::Forms::URI::Generic.resolve(file_str), file_uri, true)
        end

        specify Types::Forms::URI::HTTP do
          assert_result(Types::Forms::URI::HTTP.resolve(http_uri), http_uri, true)
          assert_result(Types::Forms::URI::HTTP.resolve(file_uri), file_uri, false)
          assert_result(Types::Forms::URI::HTTP.resolve(http_str), http_uri, true)
          assert_result(Types::Forms::URI::HTTP.resolve(file_str), file_uri, false)
        end

        specify Types::Forms::URI::File do
          assert_result(Types::Forms::URI::File.resolve(http_uri), http_uri, false)
          assert_result(Types::Forms::URI::File.resolve(file_uri), file_uri, true)
          assert_result(Types::Forms::URI::File.resolve(http_str), http_uri, false)
          assert_result(Types::Forms::URI::File.resolve(file_str), file_uri, true)
        end
      end
    end

    specify Types::Date do
      date = Date.new(2024, 1, 2)
      assert_result(Types::Date.resolve(date), date, true)
      assert_result(Types::Date.resolve(10), 10, false)
    end

    specify Types::Forms::Date do
      date = Date.new(2024, 1, 2)
      date_str = '2024-01-02'
      assert_result(Types::Forms::Date.resolve(date), date, true)
      assert_result(Types::Forms::Date.resolve(date_str), date, true)
      assert_result(Types::Forms::Date.resolve(10), 10, false)
      assert_result(Types::Forms::Date.resolve('2024-'), '2024-', false)
      expect(Types::Forms::Date.metadata[:type]).to eq([Date, String])
    end

    specify Types::Time do
      time = Time.parse('2024-08-30T20:15:23Z')
      assert_result(Types::Time.resolve(time), time, true)
      assert_result(Types::Time.resolve(10), 10, false)
    end

    specify Types::Forms::Date do
      str = '2024-08-30T20:15:23Z'
      time = Time.parse(str)
      assert_result(Types::Forms::Time.resolve(time), time, true)
      assert_result(Types::Forms::Time.resolve(str), time, true)
      assert_result(Types::Forms::Time.resolve(10), 10, false)
      assert_result(Types::Forms::Time.resolve('2024-'), '2024-', false)
      expect(Types::Forms::Time.metadata[:type]).to eq([Time, String])
    end

    specify Types::Lax::String do
      assert_result(Types::Lax::String.resolve('aa'), 'aa', true)
      assert_result(Types::Lax::String.resolve(11), '11', true)
      assert_result(Types::Lax::String.resolve(11.10), '11.1', true)
      assert_result(Types::Lax::String.resolve(BigDecimal('111.2011')), '111.2011', true)
      assert_result(Types::String.resolve(true), true, false)
    end

    specify Types::Lax::Symbol do
      assert_result(Types::Lax::Symbol.resolve('foo'), :foo, true)
      assert_result(Types::Lax::Symbol.resolve(:foo), :foo, true)
    end

    specify Types::Lax::Integer do
      assert_result(Types::Lax::Integer.resolve(113), 113, true)
      assert_result(Types::Lax::Integer.resolve(113.10), 113, true)
      assert_result(Types::Lax::Integer.resolve('113'), 113, true)
      assert_result(Types::Lax::Integer.resolve('113.10'), 113, true)
      assert_result(Types::Lax::Integer.resolve('113,222.10'), 113_222, true)
      assert_result(Types::Lax::Integer.resolve('nope'), 'nope', false)
    end

    specify Types::Lax::Numeric do
      assert_result(Types::Lax::Numeric.resolve(113), 113.0, true)
      assert_result(Types::Lax::Numeric.resolve(113.10), 113.10, true)
      assert_result(Types::Lax::Numeric.resolve('113'), 113.0, true)
      assert_result(Types::Lax::Numeric.resolve('113.10'), 113.10, true)
      assert_result(Types::Lax::Numeric.resolve('113,222.10'), 113_222.10, true)
      assert_result(Types::Lax::Numeric.resolve('nope'), 'nope', false)
    end

    specify Types::Lax::Decimal do
      assert_result(Types::Lax::Decimal.resolve(BigDecimal(10)), BigDecimal(10), true)
      assert_result(Types::Lax::Decimal.resolve('10'), BigDecimal('10'), true)
      assert_result(Types::Lax::Decimal.resolve(10.30), BigDecimal('10.30'), true)
      assert_result(Types::Lax::Decimal.resolve('10,222,333.30'), BigDecimal('10222333.30'), true)
      assert_result(Types::Lax::Decimal.resolve('10222333.30'), BigDecimal('10222333.30'), true)
    end

    specify Types::Forms::Boolean do
      assert_result(Types::Forms::Boolean.resolve(true), true, true)
      assert_result(Types::Forms::Boolean.resolve(false), false, true)
      assert_result(Types::Forms::Boolean.resolve('true'), true, true)

      assert_result(Types::Forms::Boolean.resolve('false'), false, true)
      assert_result(Types::Forms::Boolean.resolve('1'), true, true)
      assert_result(Types::Forms::Boolean.resolve('0'), false, true)
      assert_result(Types::Forms::Boolean.resolve(1), true, true)
      assert_result(Types::Forms::Boolean.resolve(0), false, true)

      assert_result(Types::Forms::Boolean.resolve('nope'), 'nope', false)
    end

    specify 'pattern matching' do
      Types::String.with(size: 3)
      [:ok, 'sup'] => [symbol => sym, three_chars => chars]

      expect(sym).to eq(:ok)
      expect(chars).to eq('sup')
    end
  end

  describe Types::Tuple do
    specify 'no member types defined' do
      assert_result(Types::Tuple.resolve(1), 1, false)
    end

    specify '#[]' do
      type = Types::Tuple[
        Types::Any.value('ok') | Types::Any.value('error'),
        Types::Boolean,
        Types::String
      ]

      assert_result(
        type.resolve(['ok', true, 'Hi!']),
        ['ok', true, 'Hi!'],
        true
      )

      assert_result(
        type.resolve(['ok', 'nope', 'Hi!']),
        ['ok', 'nope', 'Hi!'],
        false
      )

      assert_result(
        type.resolve(['ok', true, 'Hi!', 'nope']),
        ['ok', true, 'Hi!', 'nope'],
        false
      )
    end

    specify 'with static values' do
      type = Types::Tuple[2, Types::String]
      assert_result(
        type.resolve([2, 'yup']),
        [2, 'yup'],
        true
      )
      assert_result(
        type.resolve(%w[nope yup]),
        %w[nope yup],
        false
      )
    end

    specify 'with primitive classes' do
      type = Types::Tuple[::String, ::Integer]
      assert_result(type.resolve(['Ismael', 42]), ['Ismael', 42], true)
      assert_result(type.resolve([23, 42]), [23, 42], false)
    end
  end

  describe Types::Array do
    specify 'no member types defined' do
      assert_result(Types::Array.resolve(1), 1, false)
      assert_result(Types::Array.resolve([]), [], true)
    end

    specify '#[element_type]' do
      assert_result(
        Types::Array[Types::Boolean].resolve([true, true, false]),
        [true, true, false],
        true
      )
      assert_result(
        Types::Array.of(Types::Boolean).resolve([]),
        [],
        true
      )
      Types::Array.of(Types::Boolean).resolve([true, 'nope', false, 1]).tap do |result|
        expect(result.valid?).to be false
        expect(result.value).to eq [true, 'nope', false, 1]
        expect(result.errors[1]).to eq(['Must be a TrueClass', 'Must be a FalseClass'])
        expect(result.errors[3]).to eq(['Must be a TrueClass', 'Must be a FalseClass'])
      end
    end

    specify '#[] with some invalid values' do
      assert_result(
        Types::Array[Types::Lax::Integer].resolve(%w[10 nope 20]),
        [10, 'nope', 20],
        false
      )
    end

    specify '#[] with unions' do
      assert_result(
        Types::Array.of(Types::Any.value('a') | Types::Any.value('b')).resolve(%w[a b a]),
        %w[a b a],
        true
      )
      assert_result(
        Types::Array.of(Types::Boolean).default([true].freeze).resolve(Plumb::Undefined),
        [true],
        true
      )
    end

    specify '#[] (#of) Hash argument wraps subtype in Types::Hash' do
      type = Types::Array[foo: Types::String]
      assert_result(type.resolve([{ foo: 'bar' }]), [{ foo: 'bar' }], true)
    end

    specify '#[] with primitive values' do
      type = Types::Array[::String]
      assert_result(type.resolve(%w[Ismael Joe]), %w[Ismael Joe], true)
    end

    specify '#[] (#of) with literal argument' do
      type = Types::Array['bar']
      assert_result(type.resolve(%w[bar]), %w[bar], true)
      assert_result(type.resolve(%w[foo]), %w[foo], false)
    end

    specify '#present (non-empty)' do
      non_empty_array = Types::Array.of(Types::Boolean).present
      assert_result(
        non_empty_array.resolve([true, true, false]),
        [true, true, false],
        true
      )
      assert_result(
        non_empty_array.resolve([]),
        [],
        false
      )
    end

    specify '#metadata' do
      type = Types::Array[Types::Boolean].metadata(foo: 1)
      expect(type.metadata).to eq(type: Array, foo: 1)

      type = Types::Lax::Integer.metadata(foo: 1)
      expect(type.resolve('10').value).to eq(10)
    end

    specify '#metadata compared with #==' do
      t1 = Types::Array[Types::Boolean].metadata(foo: 1)
      t2 = Types::Array[Types::Boolean].metadata(foo: 1)
      t3 = Types::Array[Types::Boolean].metadata(foo: 2)
      expect(t1 == t2).to be(true)
      expect(t1 == t3).to be(false)
    end

    specify '#concurrent' do
      slow_type = Types::Any.transform(NilClass) do |r|
        sleep(0.02)
        r
      end
      array = Types::Array.of(slow_type).concurrent
      assert_result(array.resolve(1), 1, false)
      result, elapsed = bench do
        array.resolve(%w[a b c])
      end
      assert_result(result, %w[a b c], true)
      expect(elapsed).to be < 30

      assert_result(array.nullable.resolve(nil), nil, true)
    end

    specify '#stream' do
      stream = Types::Array[Integer].stream
      results = stream.parse([1, 2, 'd', 4])
      expect(results.map(&:valid?)).to eq([true, true, false, true])
    end

    specify '#filtered' do
      array = Types::Array[String].filtered
      expect(array.parse([1, 'a', 2, 'b', 'c', 3])).to eq(%w[a b c])
    end
  end

  specify Types::SymbolizedHash do
    input = {'name' => 'Joe', 'address' => {'street' => '123 St', number: 32}}
    output = {name: 'Joe', address: {street: '123 St', number: 32}}
    assert_result(Types::SymbolizedHash.resolve(input), output, true)
  end

  describe Types::Hash do
    specify 'no schema' do
      assert_result(Types::Hash.resolve({ foo: 1 }), { foo: 1 }, true)
      assert_result(Types::Hash.resolve(1), 1, false)
    end

    specify '#schema' do
      hash = Types::Hash.schema(
        title: Types::String.default('Mr'),
        name: Types::String,
        age: Types::Lax::Integer,
        friend: Types::Hash.schema(name: Types::String)
      )

      assert_result(hash.resolve({ name: 'Ismael', age: '42', friend: { name: 'Joe' } }),
                    { title: 'Mr', name: 'Ismael', age: 42, friend: { name: 'Joe' } }, true)

      hash.resolve({ title: 'Dr', name: 'Ismael', friend: {} }).tap do |result|
        expect(result.valid?).to be false
        expect(result.value).to eq({ title: 'Dr', name: 'Ismael', friend: {} })
        expect(result.errors[:age].any?).to be(true)
        expect(result.errors[:friend][:name]).to be_a(::String)
      end
    end

    specify '#==' do
      hash1 = Types::Hash[title: Types::String.default('Mr')]
      hash2 = Types::Hash[title: Types::String.default('Mr')]
      hash3 = Types::Hash[title: Types::String.default('Mrs')]
      expect(hash1 == hash2).to be(true)
      expect(hash1 == hash3).to be(false)
    end

    specify 'schema with static values' do
      hash = Types::Hash[
        title: Types::String.default('Mr'),
        name: Types::Static['Ismael'],
        age: Types::Static[45],
        friend: Types::Hash.schema(name: Types::String)
      ]

      assert_result(hash.resolve({ friend: { name: 'Joe' } }),
                    { title: 'Mr', name: 'Ismael', age: 45, friend: { name: 'Joe' } }, true)
    end

    specify 'schema with primitive classes' do
      hash = Types::Hash[name: ::String, age: ::Integer]
      assert_result(hash.resolve(name: 'Ismael', age: 42), { name: 'Ismael', age: 42 }, true)
    end

    specify 'schema with nested hash' do
      hash = Types::Hash[user: { name: String }]
      assert_result(hash.resolve(user: { name: 'Ismael' }), { user: { name: 'Ismael' } }, true)
    end

    specify 'schema with array value' do
      hash = Types::Hash[numbers: [Integer]]
      assert_result(hash.resolve(numbers: [1, 2, 3]), { numbers: [1, 2, 3] }, true)
    end

    specify 'string keys' do
      hash = Types::Hash[
        'name' => String, 
        'numbers' => [Integer],
        'age?' => Integer
      ]

      assert_result(hash.resolve('name' => 'joe', 'numbers' => [1, 2, 3]), { 'name' => 'joe', 'numbers' => [1, 2, 3] }, true)
    end

    specify 'string keys with special characters' do
      hash = Types::Hash['$ref' => String]
      assert_result(hash.resolve('$ref' => '#/components/schemas/Pet'), { '$ref' => '#/components/schemas/Pet' }, true)
    end

    specify '#|' do
      hash1 = Types::Hash.schema(foo: Types::String)
      hash2 = Types::Hash.schema(bar: Types::Integer)
      union = hash1 | hash2

      assert_result(union.resolve(foo: 'bar'), { foo: 'bar' }, true)
      assert_result(union.resolve(bar: 10), { bar: 10 }, true)
      assert_result(union.resolve(bar: '10'), { bar: '10' }, false)
    end

    specify '#+' do
      s1 = Types::Hash.schema(name: Types::String)
      s2 = Types::Hash.schema(name?: Types::String, age: Types::Integer)
      s3 = s1 + s2

      assert_result(s3.resolve(name: 'Ismael', age: 42), { name: 'Ismael', age: 42 }, true)
      assert_result(s3.resolve(age: 42), { age: 42 }, true)
    end

    specify '#+ (merge) with Hash' do
      s1 = Types::Hash[name: String]
      s2 = s1 + { age: Integer }
      assert_result(s2.resolve(name: 'Joe', age: 42), { name: 'Joe', age: 42 }, true)
    end

    specify '#filtered' do
      hash = Types::Hash[name: String, age: Integer].filtered
      expect(hash.parse(name: 'Ismael', age: 46, address: 'foo bar'))
        .to eq(name: 'Ismael', age: 46)

      expect(hash.parse(name: 'Ismael', age: 'nope'))
        .to eq(name: 'Ismael')
    end

    specify '#defer' do
      linked_list = Types::Hash[
        value: Types::Any,
        next: Types::Any.defer { linked_list } | Types::Nil
      ]
      assert_result(
        linked_list.resolve(value: 1, next: { value: 2, next: { value: 3, next: nil } }),
        { value: 1, next: { value: 2, next: { value: 3, next: nil } } },
        true
      )
      expect(linked_list.metadata).to eq(type: Hash)
    end

    specify 'deferring definition with a regular proc' do
      linked_list = Types::Hash[
        value: Types::Any,
        next: Types::Nil | proc { |result| linked_list.(result) }
      ]
      assert_result(
        linked_list.resolve(value: 1, next: { value: 2, next: { value: 3, next: nil } }),
        { value: 1, next: { value: 2, next: { value: 3, next: nil } } },
        true
      )
      expect(linked_list.metadata).to eq(type: Hash)
    end

    specify '#defer with Tuple' do
      type = Types::Tuple[
        Types::String,
        Types::Hash,
        Types::Array[Types::Any.defer { type }]
      ]
      assert_result(
        type.resolve(['hello', { foo: 'bar' }, [['ok', {}, []]]]),
        ['hello', { foo: 'bar' }, [['ok', {}, []]]],
        true
      )
      assert_result(
        type.resolve(['hello', { foo: 'bar' }, [['ok', {}, 1]]]),
        ['hello', { foo: 'bar' }, [['ok', {}, 1]]],
        false
      )
    end

    specify '#defer with Array' do
      type = Types::Array[Types::Any.defer { Types::String }]
      assert_result(
        type.resolve(['hello']),
        ['hello'],
        true
      )
      expect(type.metadata).to eq(type: Array)
      # TODO: Deferred #ast cannot delegate to the deferred type
      # to avoid infinite recursion. Deferred should only be used
      # for recursive types such as Linked Lists, Trees, etc.
      # expect(type.ast).to eq([:array, {}, [:string, {}]])
    end

    specify '#&' do
      s1 = Types::Hash.schema(name: Types::String, age: Types::Integer, company: Types::String)
      s2 = Types::Hash.schema(name?: Types::String, age: Types::Integer, email: Types::String)
      s3 = s1 & s2

      assert_result(s3.resolve(name: 'Ismael', age: 42, company: 'ACME', email: 'me@acme.com'),
                    { name: 'Ismael', age: 42 }, true)
      assert_result(s3.resolve(age: 42), { age: 42 }, true)
    end

    specify '#metadata' do
      s1 = Types::Hash.schema(name: Types::String, age: Types::Integer, company: Types::String)
      expect(s1.metadata).to eq(type: Hash)
    end

    specify '#tagged_by' do
      t1 = Types::Hash[kind: 't1', name: Types::String]
      t2 = Types::Hash[kind: 't2', name: Types::String]
      type = Types::Hash.tagged_by(:kind, t1, t2)

      assert_result(type.resolve(kind: 't1', name: 'T1'), { kind: 't1', name: 'T1' }, true)
      assert_result(type.resolve(kind: 't2', name: 'T2'), { kind: 't2', name: 'T2' }, true)
      assert_result(type.resolve(kind: 't3', name: 'T2'), { kind: 't3', name: 'T2' }, false)
    end

    specify '#>>' do
      s1 = Types::Hash.schema(name: Types::String)
      s2 = Types::Any.transform(::String) { |v| "Name is #{v[:name]}" }

      pipe = s1 >> s2
      assert_result(pipe.resolve(name: 'Ismael', age: 42), 'Name is Ismael', true)
      assert_result(pipe.resolve(age: 42), {}, false)
    end

    specify '#present' do
      assert_result(Types::Hash.resolve({}), {}, true)
      assert_result(Types::Hash.present.resolve({}), {}, false)
    end

    specify 'optional keys' do
      hash = Types::Hash.schema(
        title: Types::String.default('Mr'),
        name?: Types::String,
        age?: Types::Lax::Integer
      )

      assert_result(hash.resolve({}), { title: 'Mr' }, true)
    end

    describe '#[key_type, value_type] (Hash Map)' do
      specify 'recursive' do
        deep_hash = Types::Hash[
          (Types::Symbol | Types::String.transform(Symbol, &:to_sym)),
          Types::Any.defer { deep_hash } | Types::Any
        ]
        assert_result(deep_hash.resolve('a' => 1, 'b' => 2, c: { 'd' => 3 }), { a: 1, b: 2, c: { d: 3 } }, true)
      end

      it 'validates keys and values' do
        s1 = Types::Hash[Types::String, Types::Integer]
        expect(s1.metadata).to eq(type: Hash)
        assert_result(s1.resolve('a' => 1, 'b' => 2), { 'a' => 1, 'b' => 2 }, true)
        s1.resolve(a: 1, 'b' => 2).tap do |result|
          assert_result(result, { a: 1, 'b' => 2 }, false)
          expect(result.errors).to eq(a: ['key Must be a String'])
        end
        s1.resolve('a' => 1, 'b' => {}).tap do |result|
          assert_result(result, { 'a' => 1, 'b' => {} }, false)
          expect(result.errors).to eq('b' => ['value {} Must be a Integer'])
        end
        assert_result(s1.present.resolve({}), {}, false)
      end

      it 'supports primitive values and classes' do
        s1 = Types::Hash[::String, ::Integer]
        assert_result(s1.resolve('ok' => 1, 'foo' => 2), { 'ok' => 1, 'foo' => 2 }, true)
        assert_result(s1.resolve(:ok => 1, 'foo' => 2), { :ok => 1, 'foo' => 2 }, false)

        s2 = Types::Hash[/^foo/, ::Integer]
        assert_result(s2.resolve('foo_one' => 1, 'foo_two' => 2), { 'foo_one' => 1, 'foo_two' => 2 }, true)
        assert_result(s2.resolve('foo_one' => 1, 'nope' => 2), { 'foo_one' => 1, 'nope' => 2 }, false)
      end

      specify '#filtered' do
        s1 = Types::Hash[Types::String, Types::Integer].filtered
        expect(s1.parse('a' => 1, 20 => 'nope', 'b' => 2)).to eq('a' => 1, 'b' => 2)
      end

      specify '#==' do
        s1 = Types::Hash[Types::String, Types::Integer]
        s2 = Types::Hash[Types::String, Types::Integer]
        s3 = Types::Hash[Types::String, Types::String]
        expect(s1 == s2).to be(true)
        expect(s1 == s3).to be(false)
      end
    end

    specify '#[] alias to #schema' do
      s1 = Types::Hash[Types::String, Types::Integer]
      expect(s1.metadata).to eq(type: Hash)
      assert_result(s1.resolve('a' => 1, 'b' => 2), { 'a' => 1, 'b' => 2 }, true)
    end

    specify '#inclusive' do
      exclusive = Types::Hash[age: Types::Lax::Integer]
      inclusive = exclusive.inclusive
      data = { name: 'Joe', age: '10' }
      assert_result(exclusive.resolve(data), { age: 10 }, true)
      assert_result(inclusive.resolve(data), { name: 'Joe', age: 10 }, true)
    end
  end

  specify '#to_json_schema' do
    expect((Types::String | Types::Integer).to_json_schema)
      .to eq({ 'anyOf' => [{ 'type' => 'string' }, { 'type' => 'integer' }] })
  end

  private

  def bench
    start = Time.now
    result = yield
    elapsed = (Time.now - start).to_f * 1000
    [result, elapsed]
  end
end

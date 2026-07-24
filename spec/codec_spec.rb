# frozen_string_literal: true

require 'spec_helper'

module CodecSpecTypes
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

  class JSONCodec < Plumb::Codec::JSON
    encoder DateRangeEncoder
    encoder ISODateEncoder
  end

  Person = Types::Hash[name: Types::String, dates: DateRange]

  class Company < Types::Data
    attribute :name, Types::String
    attribute :founded, Types::Date
  end

  class PlainEmployee
    include Plumb::Attributes
    attribute :name, Types::String
    attribute :joined, Types::Date
  end

  class Team < Types::Data
    attribute :title, Types::String
    attribute :company, Company
    attribute :members, Types::Array[PlainEmployee].default([].freeze)
    attribute? :dates, DateRange
  end

  Tree = Types::Hash[
    value: Types::Date,
    children: Types::Array[Types::Any.defer { Tree }]
  ]

  DATE = ::Date.new(2024, 1, 1).freeze
  RANGE = ::Date.new(2024, 1, 1)..::Date.new(2024, 2, 1)
  ENCODED_PERSON = { name: 'Joe', dates: { from: '2024-01-01', to: '2024-02-01' } }.freeze
  PERSON = { name: 'Joe', dates: RANGE }.freeze

  RSpec.describe Plumb::Codec do
    describe 'definition' do
      it 'registers encoders and noops, inheritable through subclasses' do
        expect(JSONCodec.encoders).to include(DateRangeEncoder, ISODateEncoder)
        expect(JSONCodec.noop_types).to include(Types::String)
        sub = Class.new(JSONCodec)
        expect(sub.encoders).to include(DateRangeEncoder)
        expect(sub.noop_types).to include(Types::String)
      end

      it 'validates encoder registration' do
        expect { Class.new(described_class) { encoder ::String } }
          .to raise_error(ArgumentError, /expected an Encoder subclass/)
      end

      it 'supports instance construction with extra encoders' do
        codec = Plumb::Codec::JSON.new(ISODateEncoder)
        expect((codec >> Types::Date).parse('2024-01-01')).to eq(DATE)
      end
    end

    describe 'Codec::JSON built-ins' do
      it 'encodes and decodes Dates as ISO 8601 strings out of the box' do
        expect((Plumb::Codec::JSON >> Types::Date).parse('2024-01-01')).to eq(DATE)
        expect((Types::Date >> Plumb::Codec::JSON).parse(DATE)).to eq('2024-01-01')
      end

      it 'rejects non-ISO date strings at the input type' do
        expect((Plumb::Codec::JSON >> Types::Date).resolve('01/30/2024').valid?).to be(false)
      end

      it 'describes date fields with format: date in JSON Schema' do
        schema = Plumb::JSONSchemaVisitor.call(Plumb::Codec::JSON >> Types::Hash[date: Types::Date])
        expect(schema.dig('properties', 'date')).to eq('type' => 'string', 'format' => 'date')
      end

      it 'encodes and decodes Times and URIs via the shared encoders' do
        time = ::Time.parse('2024-08-30T20:15:23Z')
        expect((Plumb::Codec::JSON >> Types::Time).parse('2024-08-30T20:15:23Z')).to eq(time)
        expect((Types::Time >> Plumb::Codec::JSON).parse(time)).to eq('2024-08-30T20:15:23Z')

        uri = URI.parse('http://example.com')
        expect((Plumb::Codec::JSON >> Types::URI::HTTP).parse('http://example.com')).to eq(uri)
        expect((Types::URI::HTTP >> Plumb::Codec::JSON).parse(uri)).to eq('http://example.com')
      end

      it 'encodes and decodes Symbols as strings, keeping narrowed checks' do
        expect((Plumb::Codec::JSON >> Types::Symbol).parse('active')).to eq(:active)
        expect((Types::Symbol >> Plumb::Codec::JSON).parse(:active)).to eq('active')

        enum = Types::Symbol[%i[draft published].to_set]
        decoder, = Plumb::Codec::JSON.for(enum)
        expect(decoder.parse('draft')).to eq(:draft)
        expect(decoder.resolve('nope').valid?).to be(false)
      end

      it 'encodes and decodes Decimals as canonical strings (not via the Numeric noop)' do
        decoder, encoder = Plumb::Codec::JSON.for(Types::Decimal)
        expect(decoder.parse('1.5')).to eq(BigDecimal('1.5'))
        expect(encoder.parse(BigDecimal('1.5'))).to eq('1.5') # a string: BigDecimal is not JSON-native
      end

      it 'encodes and decodes Ranges as objects, generic over the member type' do
        # Range[Date]: endpoints rewrite to ISO strings via the Date encoder.
        dec, enc = Plumb::Codec::JSON.for(Types::Range[Types::Date])
        encoded = { from: '2024-01-01', to: '2024-02-01', exclusive: false }
        expect(enc.parse(RANGE)).to eq(encoded)
        expect(dec.parse(encoded)).to eq(RANGE)

        # Range[Integer]: JSON-native endpoints pass through; `exclusive` tracks
        # exclusive ranges, and beginless/endless ranges keep a nil endpoint.
        dec, enc = Plumb::Codec::JSON.for(Types::Range[Types::Integer])
        expect(enc.parse(1...5)).to eq({ from: 1, to: 5, exclusive: true })
        expect(dec.parse(enc.parse(1...5))).to eq(1...5)
        expect(dec.parse(enc.parse(1..))).to eq(1..)
        expect(dec.parse(enc.parse(..5))).to eq(..5)
      end

      it 'reports a bad Range endpoint under its input key' do
        dec, = Plumb::Codec::JSON.for(Types::Range[Types::Date])
        result = dec.resolve({ from: 'nope', to: '2024-02-01', exclusive: false })
        expect(result.valid?).to be(false)
        expect(result.errors[:from]).to be_truthy
      end

      it 'describes a Range field as a input object in JSON Schema' do
        schema = Plumb::JSONSchemaVisitor.call(Plumb::Codec::JSON >> Types::Hash[span: Types::Range[Types::Date]])
        span = schema.dig('properties', 'span')
        expect(span['type']).to eq('object')
        expect(span.dig('properties', 'from', 'anyOf')).to include('format' => 'date', 'type' => 'string')
        expect(span.dig('properties', 'exclusive')).to eq('type' => 'boolean')
      end

      it 'lets a subclass Date encoder take precedence over the built-in' do
        expect((Types::Date >> JSONCodec).parse(DATE)).to eq('2024-01-01') # spec ISODateEncoder wins the tie
        schema = Plumb::JSONSchemaVisitor.call(JSONCodec >> Types::Hash[date: Types::Date])
        expect(schema.dig('properties', 'date')).to eq('type' => 'string') # no format: plain input String
      end
    end

    describe '#for' do
      it 'returns a [decoding, encoding] pair for a type' do
        decoder, encoder = JSONCodec.for(Person)
        expect(decoder.parse(ENCODED_PERSON)).to eq(PERSON)
        expect(encoder.parse(PERSON)).to eq(ENCODED_PERSON)
      end

      it 'works on instances and wraps raw types' do
        decoder, encoder = Plumb::Codec::JSON.instance.for(::Date)
        expect(decoder.parse('2024-01-01')).to eq(DATE)
        expect(encoder.parse(DATE)).to eq('2024-01-01')
      end

      it 'produces an encoder and decoder that compose (encode >> decode) — they meet at the input type' do
        decoder, encoder = JSONCodec.for(Person)
        roundtrip = encoder >> decoder # Person -> encoded -> Person; type-checks at the shared input schema
        expect(roundtrip.parse(PERSON)).to eq(PERSON)
      end
    end

    describe 'composition with any type (scalar roots)' do
      it 'decodes a matched scalar' do
        expect((JSONCodec >> Types::Date).parse('2024-01-01')).to eq(DATE)
      end

      it 'encodes a matched scalar' do
        expect((Types::Date >> JSONCodec).parse(DATE)).to eq('2024-01-01')
      end

      it 'returns a noop-matched type unchanged' do
        expect(JSONCodec >> Types::String).to equal(Types::String)
      end

      it 'raises for an unmatched root' do
        expect { JSONCodec >> Types::Any[::Regexp] }
          .to raise_error(Plumb::TypeError, /the root type .* matches no encoder/)
      end
    end

    describe 'decoding schemas (Codec >> Type)' do
      it 'rewrites matched fields, resolving the input type through the same codec' do
        json_person = JSONCodec >> Person
        expect(json_person.parse(ENCODED_PERSON)).to eq(PERSON)
      end

      it 'reports errors under the failing field' do
        json_person = JSONCodec >> Person
        result = json_person.resolve({ name: 'Joe', dates: { from: 'nope', to: '2024-02-01' } })
        expect(result.valid?).to be(false)
        expect(result.errors[:dates]).to be_a(::Hash)
      end
    end

    describe 'encoding schemas (Type >> Codec)' do
      it 'rewrites the schema output to encoded values' do
        encoded_person = Person >> JSONCodec
        expect(encoded_person.parse(PERSON)).to eq(ENCODED_PERSON)
      end

      it 'still validates the decoded input' do
        encoded_person = Person >> JSONCodec
        assert_result(encoded_person.resolve({ name: 'Joe', dates: 'nope' }), { name: 'Joe', dates: 'nope' }, false)
      end

      it 'does not re-run field coercions on already-parsed values' do
        succ_type = Types::Integer.transform(::Integer, &:succ)
        schema = Types::Hash[n: succ_type]
        expect((schema >> JSONCodec).parse({ n: 5 })).to eq({ n: 6 }) # succ once, not twice
      end

      it 'round-trips' do
        decoded = (JSONCodec >> Person).parse(ENCODED_PERSON)
        expect((Person >> JSONCodec).parse(decoded)).to eq(ENCODED_PERSON)
      end
    end

    describe 'deep rewriting' do
      it 'recurses into nested Hash schemas' do
        schema = Types::Hash[profile: Types::Hash[dates: DateRange]]
        decoded = (JSONCodec >> schema).parse({ profile: { dates: { from: '2024-01-01', to: '2024-02-01' } } })
        expect(decoded).to eq({ profile: { dates: RANGE } })
      end

      it 'recurses into Arrays' do
        schema = Types::Hash[dates: Types::Array[Types::Date]]
        expect((JSONCodec >> schema).parse({ dates: %w[2024-01-01 2024-02-01] }))
          .to eq({ dates: [DATE, ::Date.new(2024, 2, 1)] })
        expect((schema >> JSONCodec).parse({ dates: [DATE] })).to eq({ dates: ['2024-01-01'] })
      end

      it 'recurses into Tuples' do
        schema = Types::Tuple[Types::String, Types::Date]
        expect((JSONCodec >> schema).parse(['a', '2024-01-01'])).to eq(['a', DATE])
      end

      it 'recurses into HashMap values' do
        schema = Types::Hash[Types::Symbol, Types::Date]
        expect((JSONCodec >> schema).parse({ a: '2024-01-01' })).to eq({ a: DATE })
      end

      it 'recurses into Or branches' do
        schema = Types::Hash[dates: DateRange | Types::Nil]
        codec_schema = JSONCodec >> schema
        expect(codec_schema.parse({ dates: nil })).to eq({ dates: nil })
        expect(codec_schema.parse({ dates: { from: '2024-01-01', to: '2024-02-01' } })).to eq({ dates: RANGE })
      end

      it 'rewrites containers inside unions even when a container-top noop is registered' do
        union = Types::Array[Types::Date] | Types::String
        codec_union = JSONCodec >> union
        expect(codec_union.parse(['2024-01-01'])).to eq([DATE]) # not swallowed by `noop Types::Array`
        expect(codec_union.parse('plain')).to eq('plain')
      end

      it 'preserves Metadata wrappers' do
        schema = Types::Hash[date: Types::Date.metadata(label: 'When')]
        codec_schema = JSONCodec >> schema
        expect(codec_schema.parse({ date: '2024-01-01' })).to eq({ date: DATE })
        expect(codec_schema.at_key(:date).metadata[:label]).to eq('When')
      end

      it 'sees through a constraint/policy stacked on a Metadata node' do
        # `Types::String.metadata(desc:).present` nests as Policy(present) -> Constraint(base:
        # Metadata -> String). The codec must see through both wrappers to the leaf — whether a
        # noop (String) or an encoder-matched type (Date) — in BOTH directions.
        noop_type = Types::String.metadata(desc: 'example').present
        expect { JSONCodec >> noop_type }.not_to raise_error
        expect((JSONCodec >> noop_type).parse('hello')).to eq('hello')
        expect((JSONCodec >> noop_type).resolve('').valid?).to be(false) # refinement still enforced

        encoded_type = Types::Date.metadata(desc: 'when').present
        decoder, encoder = JSONCodec.for(Types::Hash[on: encoded_type])
        expect(decoder.parse({ on: '2024-01-01' })).to eq({ on: DATE })
        expect(encoder.parse({ on: DATE })).to eq({ on: '2024-01-01' })
      end

      it 'preserves policies (eg. #default)' do
        schema = Types::Hash[name: Types::String.default('Unknown'), date: Types::Date]
        codec_schema = JSONCodec >> schema
        expect(codec_schema.parse({ date: '2024-01-01' })).to eq({ name: 'Unknown', date: DATE })
      end

      it 'supports #default with container values, in both directions' do
        type = Types::Array[Types::Integer].default([].freeze)
        decoder, encoder = Plumb::Codec::JSON.for(type)
        expect(decoder.parse).to eq([])
        expect(decoder.parse([1, 2])).to eq([1, 2])
        expect(encoder.parse([1, 2])).to eq([1, 2])
      end

      it 'supports #default with encodable values (decode emits the decoded default; encode encodes it)' do
        schema = Types::Hash[date: Types::Date.default(DATE)]
        decoder, encoder = JSONCodec.for(schema)
        expect(decoder.parse({})).to eq({ date: DATE })
        expect(decoder.parse({ date: '2024-06-01' })).to eq({ date: ::Date.new(2024, 6, 1) })
        expect(encoder.parse({})).to eq({ date: '2024-01-01' })
        expect(encoder.parse({ date: ::Date.new(2024, 6, 1) })).to eq({ date: '2024-06-01' })
      end

      it 'passes pure refinements through' do
        schema = Types::Hash[name: Types::String.present, age: Types::Integer[18..]]
        codec_schema = JSONCodec >> schema
        expect(codec_schema.parse({ name: 'Joe', age: 20 })).to eq({ name: 'Joe', age: 20 })
        expect(codec_schema.resolve({ name: '', age: 20 }).valid?).to be(false)
      end

      it 'keeps a narrowed, value-preserving field type as the output-side check' do
        narrow = Types::Date[DATE..::Date.new(2024, 12, 31)]
        schema = Types::Hash[date: narrow]
        codec_schema = JSONCodec >> schema
        expect(codec_schema.parse({ date: '2024-06-01' })).to eq({ date: ::Date.new(2024, 6, 1) })
        expect(codec_schema.resolve({ date: '2020-01-01' }).valid?).to be(false)
      end

      it 'rewrites a .where-refined field, keeping the refinement on the output side' do
        schema = Types::Hash[birthday: Types::Date.where(year: 1900..2100)]
        decoder, encoder = JSONCodec.for(schema)
        expect(decoder.parse({ birthday: '2024-01-30' })).to eq({ birthday: ::Date.new(2024, 1, 30) })
        expect(decoder.resolve({ birthday: '1800-01-30' }).valid?).to be(false) # year check runs on the decoded Date
        expect(encoder.parse({ birthday: ::Date.new(2024, 1, 30) })).to eq({ birthday: '2024-01-30' })
      end

      it 'encodes an encoder-matched static default (does not pass it raw via a broad noop)' do
        schema = Types::Hash[amount: Types::Decimal.default(BigDecimal('1.5'))]
        encoder = schema >> JSONCodec
        expect(encoder.parse({ amount: BigDecimal('1.5') })).to eq({ amount: '1.5' }) # default value encoded
        expect(encoder.parse({ amount: BigDecimal('9.9') })).to eq({ amount: '9.9' })
      end

      it 'rewrites tagged unions of encodable schemas' do
        tagged = Types::Hash.tagged_by(
          :kind,
          Types::Hash[kind: 'event', on: Types::Date],
          Types::Hash[kind: 'note', body: Types::String]
        )
        decoder, encoder = JSONCodec.for(tagged)
        expect(decoder.parse({ kind: 'event', on: '2024-01-01' })).to eq({ kind: 'event', on: DATE })
        expect(encoder.parse({ kind: 'event', on: DATE })).to eq({ kind: 'event', on: '2024-01-01' })
        expect(decoder.parse({ kind: 'note', body: 'hi' })).to eq({ kind: 'note', body: 'hi' })
      end

      it 'preserves a FilteredHashMap through rewriting (does not downgrade to strict)' do
        rewritten = JSONCodec >> Types::Hash[Types::Symbol, Types::Date].filtered
        expect(rewritten.node_name).to eq(:filtered_hash_map)
        # Leniency intact: a bad entry is dropped, not rejected wholesale.
        expect(rewritten.parse({ a: '2024-01-01', b: 'nope' })).to eq({ a: DATE })
      end

      it 'rewrites containers inside a value-preserving union (not swallowed by a container-top noop)' do
        union = Types::Array[Types::Date] | Types::String
        rewritten = JSONCodec >> union
        expect(rewritten.parse(['2024-01-01'])).to eq([DATE])
        expect(rewritten.parse('plain')).to eq('plain')
      end

      it 'rewrites recursive (Deferred) schemas lazily' do
        codec_tree = JSONCodec >> Tree
        decoded = codec_tree.parse({ value: '2024-01-01', children: [{ value: '2024-02-01', children: [] }] })
        expect(decoded).to eq({ value: DATE, children: [{ value: ::Date.new(2024, 2, 1), children: [] }] })
      end

      it 'preserves optional keys and the catch-all' do
        schema = Types::Hash[name?: Types::String, date: Types::Date, _: Types::String]
        codec_schema = JSONCodec >> schema
        expect(codec_schema.parse({ date: '2024-01-01', extra: 'kept' }))
          .to eq({ date: DATE, extra: 'kept' })
      end
    end

    describe 'noop pass-through' do
      it 'keeps noop-covered fields identical (no extra nodes)' do
        schema = Types::Hash[name: Types::String]
        expect(JSONCodec >> schema).to equal(schema)
      end

      it 'recurses into a structured Hash even with a generic Hash noop registered' do
        schema = Types::Hash[dates: DateRange]
        rewritten = JSONCodec >> schema
        expect(rewritten).not_to equal(schema)
        expect(rewritten.parse({ dates: { from: '2024-01-01', to: '2024-02-01' } })).to eq({ dates: RANGE })
      end

      it 'passes a bare Hash/Array field via the noop' do
        schema = Types::Hash[data: Types::Hash, list: Types::Array]
        expect(JSONCodec >> schema).to equal(schema)
      end

      it 'keeps a decode-safe coercion field as-is when decoding' do
        lax = Types::Hash[amount: Types::String.transform(::Integer, &:to_i)]
        expect((JSONCodec >> lax).parse({ amount: '42' })).to eq({ amount: 42 })
      end
    end

    describe 'matching' do
      it 'prefers the most specific encoder' do
        general = Class.new(Plumb::Encoder[Types::String => Types::Numeric]) do
          def encode(num) = "num:#{num}"
          def decode(str) = str.split(':').last.to_f
        end
        specific = Class.new(Plumb::Encoder[Types::String => Types::Integer]) do
          def encode(int) = "int:#{int}"
          def decode(str) = str.split(':').last.to_i
        end
        codec = Plumb::Codec::JSON.new(general, specific)
        expect((Types::Integer >> codec).parse(10)).to eq('int:10')
        expect((Types::Float >> codec).parse(1.5)).to eq('num:1.5')
      end

      it 'prefers a real encoder over a noop covering the same type' do
        codec = Class.new(Plumb::Codec::JSON) do
          noop Types::Date
          encoder CodecSpecTypes::ISODateEncoder
        end
        expect((Types::Date >> codec).parse(DATE)).to eq('2024-01-01')
      end

      it 'raises for incomparable multi-matches' do
        a = Class.new(Plumb::Encoder[Types::String => Types::Integer[0..10]]) do
          def encode(v) = v.to_s
          def decode(v) = v.to_i
        end
        b = Class.new(Plumb::Encoder[Types::String => Types::Integer[5..15]]) do
          def encode(v) = v.to_s
          def decode(v) = v.to_i
        end
        codec = Plumb::Codec::JSON.new(a, b)
        expect { Types::Integer[5..10] >> codec }
          .to raise_error(Plumb::TypeError, /matches multiple incomparable encoders/)
      end
    end

    describe 'composition-time errors' do
      it 'raises for an unmatched field with its dotted path, in both directions' do
        schema = Types::Hash[profile: Types::Hash[joined: Types::Any[::Regexp]]]
        expect { JSONCodec >> schema }
          .to raise_error(Plumb::TypeError, /field `profile\.joined`.*matches no encoder/)
        expect { schema >> JSONCodec }
          .to raise_error(Plumb::TypeError, /field `profile\.joined`.*matches no encoder/)
      end

      it 'includes array positions in the path' do
        schema = Types::Hash[times: Types::Array[Types::Any[::Regexp]]]
        expect { JSONCodec >> schema }.to raise_error(Plumb::TypeError, /field `times\.\[\]`/)
      end

      it 'detects encoder input-type cycles' do
        loop_type = Types::Range[Types::Integer]
        looping = Class.new(Plumb::Encoder[Types::Hash[again: loop_type] => loop_type]) do
          def encode(v) = { again: v }
          def decode(v) = v[:again]
        end
        codec = Plumb::Codec.new(looping)
        expect { codec >> loop_type }.to raise_error(Plumb::TypeError, /input-type cycle/)
      end

      it 'raises when composed with | or &' do
        expect { JSONCodec | Types::String }.to raise_error(Plumb::TypeError, /only composes with #>>/)
        expect { Types::String | JSONCodec }.to raise_error(Plumb::TypeError, /only composes with #>>/)
        expect { Types::String & JSONCodec }.to raise_error(Plumb::TypeError, /only composes with #>>/)
      end

      it 'raises at composition time (not parse) even from Never/Hash operands' do
        expect { Types::Never | JSONCodec }.to raise_error(Plumb::TypeError, /only composes with #>>/)
        expect { Types::Hash[a: Types::String] & JSONCodec }.to raise_error(Plumb::TypeError, /only composes with #>>/)
      end

      it 'raises when used as a runtime type' do
        expect { JSONCodec.instance.parse('x') }.to raise_error(Plumb::TypeError, /not a runtime type/)
      end
    end

    describe 'struct types (Types::Data / Plumb::Attributes)' do
      it 'decodes encoded structures into struct instances' do
        company = (JSONCodec >> Company).parse({ name: 'ACME', founded: '2024-01-01' })
        expect(company).to be_a(Company)
        expect(company.founded).to eq(DATE)
      end

      it 'encodes struct instances into encoded structures' do
        company = Company.new(name: 'ACME', founded: DATE)
        expect((Company >> JSONCodec).parse(company)).to eq({ name: 'ACME', founded: '2024-01-01' })
      end

      it 'round-trips via .for' do
        decoder, encoder = JSONCodec.for(Company)
        company = decoder.parse({ name: 'ACME', founded: '2024-01-01' })
        expect(encoder.parse(company)).to eq({ name: 'ACME', founded: '2024-01-01' })
      end

      it 'supports plain include Plumb::Attributes classes' do
        decoder, encoder = JSONCodec.for(PlainEmployee)
        employee = decoder.parse({ name: 'Joe', joined: '2024-01-01' })
        expect(employee).to be_a(PlainEmployee)
        expect(employee.joined).to eq(DATE)
        expect(encoder.parse(employee)).to eq({ name: 'Joe', joined: '2024-01-01' })
      end

      it 'recurses into nested structs, arrays of structs, defaults and encoder-matched attributes' do
        encoded = {
          title: 'Core',
          company: { name: 'ACME', founded: '2024-01-01' },
          members: [{ name: 'Joe', joined: '2024-02-01' }],
          dates: { from: '2024-01-01', to: '2024-02-01' }
        }
        decoder, encoder = JSONCodec.for(Team)
        team = decoder.parse(encoded)
        expect(team.company.founded).to eq(DATE)
        expect(team.members.first).to be_a(PlainEmployee)
        expect(team.members.first.joined).to eq(::Date.new(2024, 2, 1))
        expect(team.dates).to eq(RANGE)
        expect(encoder.parse(team)).to eq(encoded)

        defaulted = decoder.parse({ title: 'Solo', company: { name: 'ACME', founded: '2024-01-01' } })
        expect(defaulted.members).to eq([])
      end

      it 'works as a field inside plain Hash schemas' do
        schema = Types::Hash[company: Company]
        decoded = (JSONCodec >> schema).parse({ company: { name: 'ACME', founded: '2024-01-01' } })
        expect(decoded[:company]).to be_a(Company)
        expect(decoded[:company].founded).to eq(DATE)
      end

      it 'reports invalid encoded data under the failing attribute' do
        result = (JSONCodec >> Company).resolve({ name: 'ACME', founded: 'nope' })
        expect(result.valid?).to be(false)
        expect(result.errors[:founded]).to be_a(::String)
      end

      it 'lets an encoder target a struct type directly' do
        company_string = Class.new(Plumb::Encoder[Types::String => Company]) do
          def encode(company) = "#{company.name}|#{company.founded.iso8601}"

          def decode(str)
            name, founded = str.split('|')
            Company.new(name:, founded: ::Date.parse(founded))
          end
        end
        codec = Class.new(Plumb::Codec::JSON) { encoder(company_string) }
        decoded = (codec >> Company).parse('ACME|2024-01-01')
        expect(decoded).to be_a(Company)
        expect((Company >> codec).parse(decoded)).to eq('ACME|2024-01-01')
      end

      it 'raises with the attribute path for unmatched attribute types' do
        klass = Types::Data[joined_at: Types::Any[::Regexp]]
        expect { JSONCodec >> klass }.to raise_error(Plumb::TypeError, /joined_at/)
        expect { klass >> JSONCodec }.to raise_error(Plumb::TypeError, /joined_at/)
      end

      it 'describes the input side in JSON Schema' do
        schema = Plumb::JSONSchemaVisitor.call(JSONCodec >> Company)
        expect(schema.dig('properties', 'founded')).to eq('type' => 'string')
        expect(schema['required']).to eq(%w[name founded])
      end
    end

    describe 'visitors' do
      it 'describes the input side of a decoded schema' do
        schema = Plumb::JSONSchemaVisitor.call(JSONCodec >> Person)
        expect(schema['properties']['dates']).to eq(
          'type' => 'object',
          'properties' => { 'from' => { 'type' => 'string' }, 'to' => { 'type' => 'string' } },
          'required' => %w[from to]
        )
      end

      it 'visits encode-direction schemas without raising (describing the output side)' do
        schema = Plumb::JSONSchemaVisitor.call(Person >> JSONCodec)
        expect(schema['properties']['name']).to eq('type' => 'string')
      end

      it 'emits $defs/$ref for rewritten recursive schemas' do
        schema = Plumb::JSONSchemaVisitor.call(JSONCodec >> Tree)
        expect(schema.fetch('$defs').size).to eq(1)
        expect(schema.dig('properties', 'children', 'items', '$ref')).to match(%r{\A#/\$defs/})
      end

      it 'collects metadata on rewritten schemas' do
        expect { (JSONCodec >> Person).metadata }.not_to raise_error
      end
    end

    describe 'Decorator support' do
      it 'keeps encoder steps intact through Plumb.decorate' do
        json_person = JSONCodec >> Person
        decorated = Plumb.decorate(json_person) { |t| t }
        expect(decorated.parse(ENCODED_PERSON)).to eq(PERSON)
      end
    end
  end
end

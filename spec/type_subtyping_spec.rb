# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'subtyping: Plumb::Subtyping.subtype? and #<=' do
  module STypes
    include Plumb::Types
  end

  describe '#<= over atomic types' do
    it 'follows the Ruby class hierarchy' do
      expect(STypes::Integer <= STypes::Numeric).to be(true)
      expect(STypes::Numeric <= STypes::Integer).to be(false)
      expect(STypes::String <= STypes::Integer).to be(false) # disjoint
    end

    it 'treats Any as the top type' do
      expect(STypes::Integer <= STypes::Any).to be(true)
      expect(STypes::Any <= STypes::Integer).to be(false)
      expect(STypes::Any <= STypes::Any).to be(true)
    end

    it 'compares against raw Ruby classes (both are types)' do
      expect(STypes::String <= ::String).to be(true)
      expect(STypes::Integer <= ::Integer).to be(true)
      expect(STypes::Integer <= ::Numeric).to be(true)
      expect(STypes::String <= ::Integer).to be(false)
    end
  end

  describe '#<= over refinements (intersection)' do
    it 'treats a longer And chain as a subset of the bare type' do
      expect(STypes::String[/@/] <= STypes::String).to be(true)
      expect(STypes::String <= STypes::String[/@/]).to be(false)
    end

    it 'is reflexive on equal refinements' do
      expect(STypes::String[/@/] <= STypes::String[/@/]).to be(true)
    end
  end

  describe '#<= over ranges and literals' do
    it 'covers ranges' do
      expect(STypes::Integer[1..10] <= STypes::Integer[0..20]).to be(true)
      expect(STypes::Integer[0..20] <= STypes::Integer[1..10]).to be(false)
    end

    it 'places literals within ranges and classes' do
      expect(STypes::Any[5] <= STypes::Integer[1..10]).to be(true)
      expect(STypes::Any[5] <= STypes::Integer).to be(true)
      expect(STypes::Any[50] <= STypes::Integer[1..10]).to be(false)
    end
  end

  describe '#<= over unions' do
    it 'requires every left member to be covered (left union)' do
      expect((STypes::Integer | STypes::Any[Float]) <= STypes::Numeric).to be(true)
      expect((STypes::Integer | STypes::String) <= STypes::Numeric).to be(false)
    end

    it 'requires some right member to cover (right union)' do
      expect(STypes::Integer <= (STypes::String | STypes::Integer)).to be(true)
      expect(STypes::Any[Float] <= (STypes::String | STypes::Integer)).to be(false)
    end
  end

  describe '#<= over containers' do
    it 'is covariant in Array elements' do
      expect(STypes::Array[STypes::Integer] <= STypes::Array[STypes::Numeric]).to be(true)
      expect(STypes::Array[STypes::Numeric] <= STypes::Array[STypes::Integer]).to be(false)
    end

    it 'is covariant per Tuple position, with matching arity' do
      expect(STypes::Tuple[STypes::Integer, STypes::String] <= STypes::Tuple[STypes::Numeric, STypes::String]).to be(true)
      expect(STypes::Tuple[STypes::Integer] <= STypes::Tuple[STypes::Integer, STypes::String]).to be(false)
    end

    it 'is covariant over HashMap key/value types' do
      expect(STypes::Hash[STypes::String, STypes::Integer] <= STypes::Hash[STypes::String, STypes::Numeric]).to be(true)
      expect(STypes::Hash[STypes::String, STypes::Numeric] <= STypes::Hash[STypes::String, STypes::Integer]).to be(false)
    end

    it 'does width + depth subtyping over Hash schemas' do
      big = STypes::Hash[name: STypes::String, age: STypes::Integer]
      small = STypes::Hash[name: STypes::String]
      expect(big <= small).to be(true)  # big has an extra key (width)
      expect(small <= big).to be(false) # small is missing required age
    end

    it 'does depth subtyping over shared Hash keys' do
      narrow = STypes::Hash[age: STypes::Integer]
      wide = STypes::Hash[age: STypes::Numeric]
      expect(narrow <= wide).to be(true)
      expect(wide <= narrow).to be(false)
    end

    it 'treats Types::Hash (empty schema) as any-Hash within the family' do
      expect(STypes::Hash[name: STypes::String] <= STypes::Hash).to be(true)
      expect(STypes::Hash <= STypes::Hash[name: STypes::String]).to be(false)
    end
  end

  describe '#<= over conversions (Transform)' do
    it 'identifies a Transform by the value it produces (output_type)' do
      string_to_int = STypes::String.transform(::Integer, &:to_i)
      expect(string_to_int <= STypes::Integer).to be(true)
      expect(string_to_int <= STypes::String).to be(false)
    end
  end

  describe '#<= equality fallback for regexes' do
    it 'compares regex sources rather than identity' do
      expect(STypes::Any[/foo/] <= STypes::Any[/foo/]).to be(true)
      expect(STypes::Any[/foo/] <= STypes::Any[/bar/]).to be(false)
    end
  end

  describe 'derived comparison operators' do
    it 'derives >=, <, >' do
      expect(STypes::Integer >= STypes::Numeric).to be(false)
      expect(STypes::Numeric >= STypes::Integer).to be(true)
      expect(STypes::Integer < STypes::Numeric).to be(true)
      expect(STypes::Integer < STypes::Integer).to be(false)
      expect(STypes::Numeric > STypes::Integer).to be(true)
    end
  end

  describe '#<= over interfaces (duck typing)' do
    it 'a type is a subtype of an Interface its values support' do
      expect(STypes::String <= STypes::Interface[:to_s]).to be(true)
      expect(STypes::Integer <= STypes::Interface[:to_s, :+]).to be(true)
      expect(STypes::Array[STypes::Integer] <= STypes::Interface[:each]).to be(true)
      # a missing method -> not a subtype
      expect(STypes::String <= STypes::Interface[:nonexistent_xyz]).to be(false)
      # an Interface is not generally a subtype of a concrete type
      expect(STypes::Interface[:to_s] <= STypes::String).to be(false)
    end

    it 'an Interface is a subtype of a looser Interface (a subset of its methods)' do
      expect(STypes::Interface[:a, :b] <= STypes::Interface[:a]).to be(true)
      expect(STypes::Interface[:a] <= STypes::Interface[:a, :b]).to be(false)
    end

    it 'composes with #>> when the left supports the interface' do
      expect { STypes::String >> STypes::Interface[:to_s] }.not_to raise_error
      expect { STypes::String >> STypes::Interface[:nonexistent_xyz] }.to raise_error(Plumb::TypeError)
    end
  end

  describe '#<= over Data types (delegates to the schema)' do
    # NB: use Plumb::Subtyping.subtype? (or #>>), not `big <= small` — on a Data
    # *class* `<=` is Ruby's own Module#<= (class-hierarchy), not Plumb subtyping.
    it 'compares Data types by their schema (width + depth)' do
      big = STypes::Data[name: STypes::String, age: STypes::Integer]
      small = STypes::Data[name: STypes::String]
      expect(Plumb::Subtyping.subtype?(big, small)).to be(true)  # width: has small's keys
      expect(Plumb::Subtyping.subtype?(small, big)).to be(false)
      expect(Plumb::Subtyping.subtype?(big, big)).to be(true)    # reflexive
      # against a structurally-compatible Hash type, and a disjoint one
      expect(Plumb::Subtyping.subtype?(big, STypes::Hash[name: STypes::String])).to be(true)
      expect(Plumb::Subtyping.subtype?(big, STypes::Integer)).to be(false)
    end

    it 'composes Data types with #>> by schema subtyping' do
      big = STypes::Data[name: STypes::String, age: STypes::Integer]
      small = STypes::Data[name: STypes::String]
      expect { big >> small }.not_to raise_error
      expect { small >> big }.to raise_error(Plumb::TypeError)
    end
  end

  describe '#accepted_type (what a #>> consumer accepts)' do
    it 'defaults to the input type; refinements accept their output constraint' do
      money = Class.new
      # conversion/consumer types accept their declared input (via the default)
      expect(STypes::Integer.build(money).accepted_type).to eq(STypes::Integer)
      expect(STypes::Stream[STypes::Integer].accepted_type).to eq(STypes::Interface[:each])
      # a plain matcher: input == output
      expect(STypes::Integer.accepted_type).to eq(STypes::Integer)
      # a refinement accepts the constraint it passes (its output), not the base
      expect(STypes::Integer[1..10].accepted_type).to eq(STypes::Integer[1..10].output_type)
    end
  end

  describe 'composition type-checking (#>>)' do
    # `>>` is typed by subsumption: everything the left produces must be
    # acceptable to the right (produced <: accepted). Narrow with `#[]` instead.
    it 'raises when the left output is not a subtype of the right input' do
      expect { STypes::String >> STypes::Integer }.to raise_error(Plumb::TypeError)        # disjoint
      expect { STypes::Numeric >> STypes::Integer }.to raise_error(Plumb::TypeError)       # too broad
      expect { STypes::Integer[0..10] >> STypes::Integer[11..20] }.to raise_error(Plumb::TypeError) # disjoint ranges
      expect { STypes::Integer[0..40] >> STypes::Integer[2..10] }.to raise_error(Plumb::TypeError)  # left wider than right
      expect { STypes::String[/nope/] >> STypes::String['yes'] }.to raise_error(Plumb::TypeError)
      expect { STypes::String.transform(::Integer, &:to_i) >> STypes::String }.to raise_error(Plumb::TypeError)
      expect { STypes::String >> STypes::String[/d/] }.to raise_error(Plumb::TypeError)    # narrowing — use []
      expect { STypes::Array[STypes::Integer] >> STypes::Array[STypes::String] }.to raise_error(Plumb::TypeError)
    end

    it 'allows a chain when the left output is a subtype of the right input' do
      expect { STypes::Integer >> STypes::Numeric }.not_to raise_error
      expect { STypes::Integer[2..10] >> STypes::Integer[0..40] }.not_to raise_error
      expect { STypes::String[/d/] >> STypes::String }.not_to raise_error
    end

    it 'collapses a redundant `X >> X` for value validators (idempotent)' do
      expect(STypes::String >> STypes::String).to eq(STypes::String)
      expect(STypes::Integer >> STypes::Integer).to eq(STypes::Integer)
      # equal matcher built separately still collapses
      expect(STypes::String >> STypes::Any[::String]).to eq(STypes::String)
      # but a transform is NOT idempotent — `X >> X` must apply it twice
      plus5 = STypes::Any.transform(::Integer) { |v| v + 5 }
      expect(plus5 >> plus5).to be_a(Plumb::And)
      expect((plus5 >> plus5).resolve(10).value).to eq(20)
    end

    it 'narrowing is done with #[] (a runtime-checked cast), not #>>' do
      # the same narrowings that #>> rejects are fine as constraints:
      expect { STypes::Integer[0..40][2..10] }.not_to raise_error
      expect { STypes::String.transform(::Integer, &:to_i)[1..10] }.not_to raise_error
    end

    it 'lets any enumerable producer feed a Stream (its input opts out)' do
      # a Stream consumes any enumerable (checked at runtime), not another Stream,
      # so a producer of a raw Enumerator/Array can chain into it — eg. CSV rows.
      enum_producer = STypes::Any.transform(::Enumerator, &:each)
      expect { enum_producer >> STypes::Stream[STypes::Integer] }.not_to raise_error
      # covariant Stream[X] <= Stream[Y] subtyping is unaffected
      expect(STypes::Stream[STypes::Integer] <= STypes::Stream[STypes::Numeric]).to be(true)
      expect(STypes::Stream[STypes::Numeric] <= STypes::Stream[STypes::Integer]).to be(false)
    end

    it 'a Hash consumer accepts each field by what it consumes (transform fields)' do
      money = Class.new
      front = STypes::Hash[price: STypes::Integer, name: STypes::String]
      # Back converts :price (Integer -> money). As a consumer its :price field
      # *accepts* an Integer, so `front >> back` is sound and must type-check.
      back = STypes::Hash[price: STypes::Integer.build(money)].inclusive
      expect { front >> back }.not_to raise_error
      # but a field that consumes an incompatible type still raises
      bad = STypes::Hash[price: STypes::String.build(money)] # its :price consumes a String
      expect { front >> bad }.to raise_error(Plumb::TypeError)
    end

    it 'preserves the base type through a transparent #check predicate' do
      # a #check asserts about the value without changing its type, so the
      # refinement produces the base type — not the opaque proc matcher — and
      # composes cleanly with a consumer of that type.
      checked = STypes::Integer.check("positive") { |v| v.positive? }
      expect(checked.output_type).to eq(STypes::Integer)
      expect { checked >> STypes::Integer }.not_to raise_error
      # a genuinely incompatible consumer still raises (no false negative)
      expect { STypes::String >> STypes::Integer.check { |_v| true } }.to raise_error(Plumb::TypeError)
    end

    it 'composes a checked Data value into a consumer of that type' do
      user = STypes::Data[name: STypes::String]
      is_named = user.check("named") { |u| !u.name.empty? }
      # Data classes join Composable via `extend` (no Equality hooks), so this
      # also exercises the subtype? guards — it must not raise or crash.
      expect { is_named >> user }.not_to raise_error
    end

    it 'composes WITHOUT the subtype check via #/ (escape hatch)' do
      # the narrowings #>> rejects build fine with #/
      expect { STypes::Integer[0..40] / STypes::Integer[2..10] }.not_to raise_error
      expect { STypes::String / STypes::String[/d/] }.not_to raise_error

      narrowed = STypes::Integer[0..40] / STypes::Integer[2..10]
      # it's the same refinement And as a checked chain, so it still validates
      expect(narrowed).to be_a(Plumb::And)
      expect(narrowed.resolve(5).valid?).to be(true)
      expect(narrowed.resolve(30).valid?).to be(false)
      # and participates in subtyping like any other refinement
      expect(narrowed <= STypes::Integer).to be(true)
      # Any-collapse, consistent with #[]
      expect(STypes::Any / STypes::String).to eq(STypes::String)
    end

    it 'compares #where attribute constraints by value' do
      # an attribute-constrained type is a subtype of its base
      expect { STypes::Array.where(size: 10) >> STypes::Array }.not_to raise_error
      # the produced constraint is within the accepted one
      expect { STypes::Array.where(size: 10) >> STypes::Array.where(size: 8..100) }.not_to raise_error
      expect { STypes::Array.where(size: 11..14) >> STypes::Array.where(size: 10..15) }.not_to raise_error
      # the produced range is wider than the accepted one -> left can emit values the right rejects
      expect { STypes::Array.where(size: 10..15) >> STypes::Array.where(size: 11..14) }
        .to raise_error(Plumb::TypeError)
      # narrowing the other direction (any array -> sized) must go through #where, not #>>
      expect { STypes::Array >> STypes::Array.where(size: 10) }.to raise_error(Plumb::TypeError)
    end

    it 'treats Not[raw class] the same as Not[wrapped type]' do
      # a raw Ruby class and its wrapped form must build the same Not node
      expect(STypes::Not[String]).to eq(STypes::Not[STypes::String])
      expect { STypes::String >> STypes::Not[STypes::String] }.to raise_error(Plumb::TypeError)
      expect { STypes::String >> STypes::Not[String] }.to raise_error(Plumb::TypeError)
    end

    it 'cancels double negation: Not(Not(X)) == X' do
      expect(STypes::String.not.not).to eq(STypes::String)
      expect(STypes::Not[STypes::String.not]).to eq(STypes::String)
      expect(STypes::String.not.not.not).to eq(STypes::String.not) # odd count stays negated
      # so feeding a String into Not[String.not] (== "can be a String") is valid
      expect { STypes::String >> STypes::Not[STypes::String.not] }.not_to raise_error
    end

    it 'raises on Hash schemas whose shared key value types are not subtypes' do
      expect { STypes::Hash[name: STypes::String] >> STypes::Hash[name: STypes::Integer] }
        .to raise_error(Plumb::TypeError)
    end

    it 'raises when the produced Hash lacks a key the consumer requires (width)' do
      expect { STypes::Hash[name: STypes::String] >> STypes::Hash[name: STypes::String, age: STypes::Integer] }
        .to raise_error(Plumb::TypeError)
      # no shared key at all: right requires :age, left never emits it
      expect { STypes::Hash[name: STypes::String] >> STypes::Hash[age: STypes::Integer] }
        .to raise_error(Plumb::TypeError)
      # producer only holds the required key optionally -> it may omit it
      expect { STypes::Hash[name?: STypes::String] >> STypes::Hash[name: STypes::String] }
        .to raise_error(Plumb::TypeError)
    end

    it 'relates HashMap to the Hash family' do
      # a HashMap is a Hash -> subtype of the any-Hash top
      expect { STypes::Hash[STypes::Symbol, STypes::Integer] >> STypes::Hash }.not_to raise_error
      # covariant in key/value
      expect { STypes::Hash[STypes::Symbol, STypes::Integer] >> STypes::Hash[STypes::Symbol, STypes::Numeric] }
        .not_to raise_error
      expect { STypes::Hash[STypes::Symbol, STypes::Numeric] >> STypes::Hash[STypes::Symbol, STypes::Integer] }
        .to raise_error(Plumb::TypeError)
      # any-Hash is not a subtype of a specific map; a map doesn't guarantee a structured Hash's keys
      expect { STypes::Hash >> STypes::Hash[STypes::Symbol, STypes::Integer] }.to raise_error(Plumb::TypeError)
      expect { STypes::Hash[STypes::Symbol, STypes::Integer] >> STypes::Hash[name: STypes::Integer] }
        .to raise_error(Plumb::TypeError)
    end

    it 'subtypes a structured Hash to a HashMap when its keys and values fit' do
      # a non-inclusive {name: Integer} emits exactly {name: <int>}, a Symbol => Integer map
      expect { STypes::Hash[name: STypes::Integer] >> STypes::Hash[STypes::Symbol, STypes::Integer] }
        .not_to raise_error
      expect { STypes::Hash[name: STypes::Integer] >> STypes::Hash[STypes::Symbol, STypes::Numeric] }
        .not_to raise_error
      # value type clash
      expect { STypes::Hash[name: STypes::String] >> STypes::Hash[STypes::Symbol, STypes::Integer] }
        .to raise_error(Plumb::TypeError)
      # key type clash (symbol key vs String-keyed map)
      expect { STypes::Hash[name: STypes::Integer] >> STypes::Hash[STypes::String, STypes::Integer] }
        .to raise_error(Plumb::TypeError)
      # inclusive may carry entries that don't fit
      expect { STypes::Hash[name: STypes::Integer].inclusive >> STypes::Hash[STypes::Symbol, STypes::Integer] }
        .to raise_error(Plumb::TypeError)
    end

    it 'types HashClass#filtered (input is the schema, output is it relaxed)' do
      filtered = STypes::Hash[name: STypes::String, age: STypes::Integer].filtered
      # produces a relaxed Hash -> subtype of any-Hash, but not of the strict schema
      expect { filtered >> STypes::Hash }.not_to raise_error
      expect { filtered >> STypes::Hash[name: STypes::Integer] }.to raise_error(Plumb::TypeError)
      # accepts (consumer side) the schema it filters; a non-Hash producer clashes
      expect { STypes::Hash[name: STypes::String, age: STypes::Integer] >> filtered }.not_to raise_error
      expect { STypes::Integer >> filtered }.to raise_error(Plumb::TypeError)
    end

    it 'treats a FilteredHashMap like a HashMap for subtyping' do
      filtered = STypes::Hash[STypes::Symbol, STypes::Integer].filtered
      expect(filtered.node_name).to eq(:filtered_hash_map)
      expect { filtered >> STypes::Hash }.not_to raise_error
      expect { STypes::Hash[name: STypes::Integer] >> filtered }.not_to raise_error
      expect { filtered >> STypes::Hash[STypes::Symbol, STypes::Numeric].filtered }.not_to raise_error
    end

    it 'allows Hash schemas where the producer is a subtype of the consumer' do
      # same value type
      expect { STypes::Hash[name: STypes::String] >> STypes::Hash[name: STypes::String] }.not_to raise_error
      # producer's value type is a subtype (Integer <= Numeric)
      expect { STypes::Hash[name: STypes::Integer] >> STypes::Hash[name: STypes::Numeric] }.not_to raise_error
      # producer is wider (extra keys are fine)
      expect { STypes::Hash[name: STypes::String, age: STypes::Integer] >> STypes::Hash[name: STypes::String] }
        .not_to raise_error
      # the key the producer lacks is optional for the consumer
      expect { STypes::Hash[name: STypes::String] >> STypes::Hash[name: STypes::String, age?: STypes::Integer] }
        .not_to raise_error
    end

    it 'does not check value-converting steps (transform/build bypass the check)' do
      expect { STypes::String.transform(::Integer, &:to_i) }.not_to raise_error
      expect { STypes::String.build(::Integer) { |v| Integer(v) } }.not_to raise_error
    end

    it 'does not check narrowing constraints built via #[] / #value / #check' do
      expect { STypes::String[/@/] }.not_to raise_error
      expect { STypes::Any.value(5) }.not_to raise_error
      expect { STypes::Integer.check('big') { |v| v > 100 } }.not_to raise_error
    end

    it 'does not check opaque steps (generate, invoke, plain procs)' do
      expect { STypes::Integer.generate { 1 } }.not_to raise_error
      expect { STypes::String.invoke(:upcase) }.not_to raise_error
      expect { STypes::Integer >> ->(r) { r.valid(r.value.to_s) } }.not_to raise_error
    end

    it 'checks a static step against what it produces (its value)' do
      expect { STypes::Static['foo'.freeze] >> STypes::Integer }.to raise_error(Plumb::TypeError)
      expect { STypes::Integer.static('nope') }.to raise_error(Plumb::TypeError)
      expect { STypes::Integer.static(10) }.not_to raise_error
      # static ignores its input, so it never blocks a chain feeding into it
      expect { STypes::Undefined >> STypes::Static['x'.freeze] }.not_to raise_error
    end
  end

  describe 'Plumb::Subtyping.subtype?' do
    it 'normalizes raw classes/values on either side' do
      expect(Plumb::Subtyping.subtype?(STypes::Integer, ::Numeric)).to be(true)
      expect(Plumb::Subtyping.subtype?(::Integer, STypes::Numeric)).to be(true)
      expect(Plumb::Subtyping.subtype?(5, STypes::Integer)).to be(true)
      expect(Plumb::Subtyping.subtype?(5, STypes::String)).to be(false)
    end
  end
end

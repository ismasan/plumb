# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# CHARACTERISATION HARNESS for the type/computation split refactor.
#
# The refactor changes Plumb's internal representation — splitting the
# overloaded `And`/`Or` nodes, relocating the reduction rules — while promising
# that `expression.resolve(value)` keeps preserving:
#
#   - validity
#   - the resulting value
#   - accumulated errors
#   - execution order
#
# This file pins exactly that, as a CORPUS rather than type-by-type. The rest of
# the suite asserts what each type does; this asserts that the whole set keeps
# doing it while the AST underneath is rebuilt.
#
# RULES OF ENGAGEMENT
#
#   - The `resolve` expectations below (validity / value / errors) and the
#     execution-order probes MUST NOT be edited during the refactor. A failure
#     here is a regression, not a spec that needs updating.
#
#   - The AST SHAPE snapshot (spec/fixtures/ast_shapes.yml) is different: the
#     refactor deliberately changes node classes. When a shape changes, the diff
#     must be reviewed and the fixture regenerated on purpose:
#
#         REGENERATE_AST_SHAPES=1 bundle exec rspec spec/invariants_spec.rb
#
#     then read `git diff spec/fixtures/ast_shapes.yml` and confirm every line
#     is an intended change. Regenerating to make a red build green is how a
#     silent behaviour change gets through.
RSpec.describe 'refactor invariants' do
  # A single corpus entry: a built type plus the inputs it is exercised with.
  #
  # @param label [String] stable key — also the snapshot key, so don't rename
  #   without regenerating
  # @param type [Plumb::Composable]
  # @param cases [Array<Array>] [input, valid?, expected_value, expected_errors]
  #   `expected_errors` is omitted when nil (the valid case) or when the error
  #   payload is not worth pinning verbatim — pass :any to assert only that
  #   errors are present.
  Entry = Struct.new(:label, :type, :cases, keyword_init: true)

  UNDEF = Plumb::Undefined

  # ---------------------------------------------------------------------------
  # Fixtures the corpus needs
  # ---------------------------------------------------------------------------

  class Money
    attr_reader :cents

    def initialize(cents) = @cents = cents
    def ==(other) = other.is_a?(Money) && other.cents == cents
    def inspect = "#<Money #{cents}>"
  end

  # A Plumb::Implementation instance-step (parameterized) and class-step.
  class Multiplier
    include Plumb::Implementation[Types::Integer => Types::Integer]

    def initialize(factor) = @factor = factor
    private def _call(result) = result.valid(result.value * @factor)
  end

  class Downcaser
    extend Plumb::Implementation[Types::String => Types::String]

    def self._call(result) = result.valid(result.value.downcase)
  end

  Person = Types::Data[name: Types::String, age: Types::Integer]

  LinkedList = Types::Hash[
    value: Types::Integer,
    next: Types::Any.defer { LinkedList } | Types::Nil
  ]

  FormPerson, PersonForm = Plumb::Codec::Forms.for(Person)

  # ---------------------------------------------------------------------------
  # The corpus
  # ---------------------------------------------------------------------------

  # rubocop:disable Metrics/BlockLength
  CORPUS = [
    # --- tops and bottoms ---------------------------------------------------
    Entry.new(label: 'Any', type: Types::Any, cases: [
                [1, true, 1], ['x', true, 'x'], [nil, true, nil]
              ]),
    Entry.new(label: 'Never', type: Types::Never, cases: [
                [1, false, 1, :any], [nil, false, nil, :any]
              ]),
    Entry.new(label: 'Undefined', type: Types::Undefined, cases: [
                [UNDEF, true, UNDEF], [1, false, 1, :any]
              ]),

    # --- root constraints ---------------------------------------------------
    Entry.new(label: 'String', type: Types::String, cases: [
                ['a', true, 'a'], [1, false, 1, 'Must be a String']
              ]),
    Entry.new(label: 'Integer', type: Types::Integer, cases: [
                [1, true, 1], ['a', false, 'a', 'Must be a Integer']
              ]),
    Entry.new(label: 'Boolean', type: Types::Boolean, cases: [
                [true, true, true], [false, true, false], [1, false, 1, :any]
              ]),
    Entry.new(label: 'Email', type: Types::Email, cases: [
                ['a@b.com', true, 'a@b.com'], ['nope', false, 'nope', :any]
              ]),
    Entry.new(label: 'UUID::V4', type: Types::UUID::V4, cases: [
                ['9f5a5b0a-1b3d-4c5e-8f7a-2b3c4d5e6f70', true, '9f5a5b0a-1b3d-4c5e-8f7a-2b3c4d5e6f70'],
                ['nope', false, 'nope', :any]
              ]),

    # --- refinements (partial identities) -----------------------------------
    Entry.new(label: 'Integer[18..]', type: Types::Integer[18..], cases: [
                [18, true, 18], [17, false, 17, :any], ['a', false, 'a', :any]
              ]),
    Entry.new(label: 'Integer[0..100][10..] (stacked, intersects)',
              type: Types::Integer[0..100][10..], cases: [
                [10, true, 10], [100, true, 100], [9, false, 9, :any], [101, false, 101, :any]
              ]),
    Entry.new(label: 'Integer[1,2,3] (Set)', type: Types::Integer[1, 2, 3], cases: [
                [2, true, 2], [4, false, 4, :any]
              ]),
    Entry.new(label: 'String[/^a/]', type: Types::String[/^a/], cases: [
                ['abc', true, 'abc'], ['bcd', false, 'bcd', :any]
              ]),
    Entry.new(label: 'String.where(size: 1..3)', type: Types::String.where(size: 1..3), cases: [
                ['ab', true, 'ab'], ['abcd', false, 'abcd', :any], [1, false, 1, :any]
              ]),
    Entry.new(label: 'String.where(size:) chained (merges)',
              type: Types::String.where(size: 0..40).where(size: 10..100), cases: [
                ['a' * 20, true, 'a' * 20], ['a' * 5, false, 'a' * 5, :any], ['a' * 50, false, 'a' * 50, :any]
              ]),
    Entry.new(label: 'String.check', type: Types::String.check('must start with a') { |v| v.start_with?('a') },
              cases: [
                ['abc', true, 'abc'], ['bcd', false, 'bcd', 'must start with a']
              ]),
    Entry.new(label: 'Any.value(:sym)', type: Types::Any.value(:sym), cases: [
                [:sym, true, :sym], [:other, false, :other, :any]
              ]),

    # --- transforms ---------------------------------------------------------
    Entry.new(label: 'String.transform(Integer, :to_i)',
              type: Types::String.transform(::Integer, &:to_i), cases: [
                ['12', true, 12], [12, false, 12, :any]
              ]),
    Entry.new(label: 'String.transform(:to_sym) (coercion shorthand)',
              type: Types::String.transform(:to_sym), cases: [
                ['a', true, :a], [1, false, 1, :any]
              ]),
    Entry.new(label: 'Integer.build(Money)', type: Types::Integer.build(Money), cases: [
                [100, true, Money.new(100)], ['x', false, 'x', :any]
              ]),
    Entry.new(label: 'String.build(Date, :parse) rescued',
              type: Types::String.build(::Date, :parse).policy(:rescue, ::Date::Error), cases: [
                ['2024-01-02', true, ::Date.new(2024, 1, 2)], ['nope', false, 'nope', :any]
              ]),
    Entry.new(label: 'String.invoke(:downcase)', type: Types::String.invoke(:downcase), cases: [
                ['AB', true, 'ab'], [1, false, 1, :any]
              ]),
    Entry.new(label: 'String.invoke([:strip, :upcase]) (chain)',
              type: Types::String.invoke(%i[strip upcase]), cases: [
                ['  ab ', true, 'AB']
              ]),
    Entry.new(label: 'String.policy(:split)', type: Types::String.policy(:split), cases: [
                ['a,b,c', true, %w[a b c]], ['a', true, %w[a]]
              ]),

    # --- sequential composition ---------------------------------------------
    Entry.new(label: 'String >> transform (compose, converting)',
              type: Types::String >> Types::String.transform(::Integer, &:to_i), cases: [
                ['12', true, 12], [12, false, 12, :any]
              ]),
    Entry.new(label: 'transform >> transform (fuses)',
              type: Types::String.transform(::Integer, &:to_i) >> Types::Integer.build(Money), cases: [
                ['5', true, Money.new(5)]
              ]),
    Entry.new(label: 'Integer[0..100] >> Integer[-10..110] (reduces)',
              type: Types::Integer[0..100] >> Types::Integer[-10..110], cases: [
                [50, true, 50], [101, false, 101, :any]
              ]),
    Entry.new(label: 'String / String[/a/] (unchecked compose)',
              type: Types::String / Types::String[/a/], cases: [
                ['a', true, 'a'], ['b', false, 'b', :any]
              ]),

    # --- unions / choice ----------------------------------------------------
    Entry.new(label: 'String | Integer (disjoint union)',
              type: Types::String | Types::Integer, cases: [
                ['a', true, 'a'], [1, true, 1], [nil, false, nil, :any]
              ]),
    Entry.new(label: 'Integer | Numeric (absorbs to Numeric)',
              type: Types::Integer | Types::Numeric, cases: [
                [1, true, 1], [1.5, true, 1.5], ['a', false, 'a', :any]
              ]),
    Entry.new(label: 'Integer | String.transform (coercion choice)',
              type: Types::Integer | Types::String.transform(::Integer, &:to_i), cases: [
                [1, true, 1], ['2', true, 2], [nil, false, nil, :any]
              ]),
    Entry.new(label: 'String[/a/] | String[/b/] (factored union)',
              type: Types::String[/a/] | Types::String[/b/], cases: [
                ['a', true, 'a'], ['b', true, 'b'], ['c', false, 'c', :any], [1, false, 1, :any]
              ]),
    Entry.new(label: 'Lax::Integer', type: Types::Lax::Integer, cases: [
                [1, true, 1], ['2', true, 2], ['1,200', true, 1200], [2.7, true, 2], [nil, false, nil, :any]
              ]),
    Entry.new(label: 'Lax::String', type: Types::Lax::String, cases: [
                ['a', true, 'a'], [1, true, '1'], [1.5, true, '1.5']
              ]),
    Entry.new(label: 'Lax::Decimal', type: Types::Lax::Decimal, cases: [
                ['1.5', true, BigDecimal('1.5')], [2, true, BigDecimal('2')]
              ]),

    # --- intersections ------------------------------------------------------
    Entry.new(label: 'Integer[2..] & Integer[0..100] (narrows)',
              type: Types::Integer[2..] & Types::Integer[0..100], cases: [
                [50, true, 50], [1, false, 1, :any], [101, false, 101, :any]
              ]),
    Entry.new(label: 'Integer[2..10] & Integer[11..100] (empty -> Never)',
              type: Types::Integer[2..10] & Types::Integer[11..100], cases: [
                [5, false, 5, :any], [50, false, 50, :any]
              ]),
    Entry.new(label: 'String & Integer (disjoint -> Never)',
              type: Types::String & Types::Integer, cases: [
                ['a', false, 'a', :any], [1, false, 1, :any]
              ]),
    Entry.new(label: 'String.where(size: 1..3) & String[/a/] (runtime And)',
              type: Types::String.where(size: 1..3) & Types::String[/a/], cases: [
                ['ab', true, 'ab'], ['b', false, 'b', :any], ['abcd', false, 'abcd', :any]
              ]),
    Entry.new(label: 'Array[Integer] & Array[Integer[0..10]] (covariant meet)',
              type: Types::Array[Types::Integer] & Types::Array[Types::Integer[0..10]], cases: [
                [[1, 2], true, [1, 2]], [[20], false, [20], :any]
              ]),

    # --- containers ---------------------------------------------------------
    Entry.new(label: 'Array[Integer]', type: Types::Array[Types::Integer], cases: [
                [[1, 2], true, [1, 2]], [[], true, []], [['a'], false, ['a'], :any], ['a', false, 'a', :any]
              ]),
    Entry.new(label: 'Array[Lax::Integer] (coercing elements)',
              type: Types::Array[Types::Lax::Integer], cases: [
                [%w[1 2], true, [1, 2]], [[nil], false, [nil], :any]
              ]),
    Entry.new(label: 'Array.where(size: 1..2)', type: Types::Array.where(size: 1..2), cases: [
                [[1], true, [1]], [[], false, [], :any]
              ]),
    Entry.new(label: 'Tuple[String, Integer]', type: Types::Tuple[Types::String, Types::Integer], cases: [
                [['a', 1], true, ['a', 1]], [['a', 'b'], false, ['a', 'b'], :any], [['a'], false, ['a'], :any]
              ]),
    Entry.new(label: 'Hash[Symbol, Integer] (hash map)',
              type: Types::Hash[Types::Symbol, Types::Integer], cases: [
                [{ a: 1 }, true, { a: 1 }], [{ 'a' => 1 }, false, { 'a' => 1 }, :any]
              ]),
    Entry.new(label: 'Hash record', type: Types::Hash[name: Types::String, age: Types::Integer], cases: [
                [{ name: 'a', age: 1 }, true, { name: 'a', age: 1 }],
                [{ name: 'a', age: 1, extra: 2 }, true, { name: 'a', age: 1 }],
                [{ name: 'a' }, false, { name: 'a' }, :any],
                [{ name: 1, age: 'x' }, false, { name: 1, age: 'x' }, :any]
              ]),
    Entry.new(label: 'Hash record with optional + default',
              type: Types::Hash[name: Types::String, age?: Types::Integer,
                                role: Types::String.default('user')], cases: [
                                  [{ name: 'a' }, true, { name: 'a', role: 'user' }],
                                  [{ name: 'a', age: 3, role: 'admin' }, true, { name: 'a', age: 3, role: 'admin' }]
                                ]),
    Entry.new(label: 'Hash record with catch-all',
              type: Types::Hash[name: Types::String, _: Types::Integer], cases: [
                [{ name: 'a', b: 1 }, true, { name: 'a', b: 1 }],
                [{ name: 'a', b: 'x' }, false, { name: 'a', b: 'x' }, :any]
              ]),
    Entry.new(label: 'Hash record coercing field',
              type: Types::Hash[age: Types::Lax::Integer], cases: [
                [{ age: '3' }, true, { age: 3 }]
              ]),
    Entry.new(label: 'SymbolizedHash', type: Types::SymbolizedHash, cases: [
                [{ 'a' => 1 }, true, { a: 1 }],
                [{ 'u' => { 'n' => 'x' } }, true, { u: { n: 'x' } }]
              ]),
    Entry.new(label: 'LinkedList (recursive)', type: LinkedList, cases: [
                [{ value: 1, next: nil }, true, { value: 1, next: nil }],
                [{ value: 1, next: { value: 2, next: nil } }, true,
                 { value: 1, next: { value: 2, next: nil } }],
                [{ value: 1, next: { value: 'x', next: nil } }, false,
                 { value: 1, next: { value: 'x', next: nil } }, :any]
              ]),

    # --- negation, statics, interfaces --------------------------------------
    Entry.new(label: 'String.not', type: Types::String.not, cases: [
                [1, true, 1], ['a', false, 'a', :any]
              ]),
    Entry.new(label: 'Integer.static(10)', type: Types::Integer.static(10), cases: [
                [1, true, 10], [UNDEF, true, 10], ['x', true, 10]
              ]),
    Entry.new(label: 'Interface[:upcase]', type: Types::Interface[:upcase], cases: [
                ['a', true, 'a'], [1, false, 1, :any]
              ]),
    Entry.new(label: 'Range[Integer]', type: Types::Range[Types::Integer], cases: [
                [(1..2), true, (1..2)], ['a', false, 'a', :any]
              ]),

    # --- policies and wrappers ----------------------------------------------
    Entry.new(label: 'String.present', type: Types::String.present, cases: [
                ['a', true, 'a'], ['', false, '', :any]
              ]),
    Entry.new(label: 'Integer.nullable', type: Types::Integer.nullable, cases: [
                [nil, true, nil], [1, true, 1], ['a', false, 'a', :any]
              ]),
    Entry.new(label: 'String.default("x")', type: Types::String.default('x'), cases: [
                [UNDEF, true, 'x'], ['a', true, 'a'], [1, false, 1, :any]
              ]),
    Entry.new(label: 'Integer.options([1, 2])', type: Types::Integer.options([1, 2]), cases: [
                [1, true, 1], [3, false, 3, :any]
              ]),
    Entry.new(label: 'String.metadata(label:)', type: Types::String.metadata(label: 'Name'), cases: [
                ['a', true, 'a'], [1, false, 1, :any]
              ]),
    Entry.new(label: 'Any.policy(respond_to: :upcase)',
              type: Types::Any.policy(respond_to: :upcase), cases: [
                ['a', true, 'a'], [1, false, 1, :any]
              ]),

    # --- structs, implementations, codecs, pipelines ------------------------
    # An invalid struct parse still returns a (partially populated, invalid)
    # struct instance, not the input Hash.
    Entry.new(label: 'Data[name:, age:]', type: Person, cases: [
                [{ name: 'a', age: 1 }, true, Person.new(name: 'a', age: 1)],
                [{ name: 'a' }, false, Person.new(name: 'a'), :any]
              ]),
    Entry.new(label: 'Implementation instance (Multiplier)', type: Multiplier.new(3), cases: [
                [2, true, 6], ['x', false, 'x', :any]
              ]),
    Entry.new(label: 'Implementation class (Downcaser)', type: Downcaser, cases: [
                ['AB', true, 'ab'], [1, false, 1, :any]
              ]),
    Entry.new(label: 'Codec::Forms >> Person (decode)', type: FormPerson, cases: [
                [{ name: 'a', age: '3' }, true, Person.new(name: 'a', age: 3)]
              ]),
    Entry.new(label: 'Person -> form (encode)', type: PersonForm, cases: [
                [Person.new(name: 'a', age: 3), true, { name: 'a', age: '3' }]
              ]),
    Entry.new(label: 'Pipeline', type: Types::Integer.pipeline { |pl| pl.step(Types::Integer[0..10]) }, cases: [
                [5, true, 5], [50, false, 50, :any]
              ]),
    Entry.new(label: 'Function[String => Integer]',
              type: Plumb::Function[::String => ::Integer] { |r| r.valid(r.value.size) }, cases: [
                ['abc', true, 3], [1, false, 1, :any]
              ]),
    Entry.new(label: 'Stream[Integer]', type: Types::Stream[Types::Integer], cases: []),
    Entry.new(label: 'Integer.generate', type: Types::Integer.generate { 42 }, cases: [
                [1, true, 42], [UNDEF, true, 42]
              ])
  ].freeze
  # rubocop:enable Metrics/BlockLength

  it 'has unique corpus labels' do
    labels = CORPUS.map(&:label)
    expect(labels.uniq.size).to eq(labels.size)
  end

  # ---------------------------------------------------------------------------
  # 1. Behaviour: validity, value, errors.  DO NOT EDIT during the refactor.
  # ---------------------------------------------------------------------------
  describe 'resolve preserves validity, value and errors' do
    CORPUS.each do |entry|
      next if entry.cases.empty?

      context entry.label do
        entry.cases.each_with_index do |(input, valid, value, errors), idx|
          it "case #{idx}: #{input.inspect}" do
            result = entry.type.resolve(input)

            expect(result.valid?).to be(valid), lambda {
              "expected #{entry.label}.resolve(#{input.inspect}) to be " \
                "#{valid ? 'valid' : 'invalid'}, got errors: #{result.errors.inspect}"
            }
            expect(result.value).to eq(value)

            case errors
            when nil then expect(result.errors).to be_nil
            when :any then expect(result.errors).not_to be_nil
            else expect(result.errors).to eq(errors)
            end
          end
        end
      end
    end
  end

  # Streams are lazy, so they need their own assertion shape.
  describe 'Stream[Integer]' do
    let(:type) { Types::Stream[Types::Integer] }

    it 'yields valid results lazily and keeps the values' do
      results = type.parse([1, 2, 3].each).to_a
      expect(results.map(&:valid?)).to eq([true, true, true])
      expect(results.map(&:value)).to eq([1, 2, 3])
    end

    it 'reports per-element invalidity without raising' do
      results = type.parse([1, 'x'].each).to_a
      expect(results.map(&:valid?)).to eq([true, false])
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Execution order.  DO NOT EDIT during the refactor.
  #
  # An optimisation rewrite that reorders, duplicates or drops a step is
  # invisible to the value/validity assertions above whenever the steps are
  # individually value-preserving. These probes make it visible: each step
  # appends a marker to a shared log, and the log is asserted verbatim.
  # ---------------------------------------------------------------------------
  describe 'execution order' do
    # A value-preserving step that records that it ran.
    #
    # Wrapped in #as_node so that two probes are DISTINCT nodes. An opaque
    # Function's children are `[Any, Any]` regardless of its callable, so two
    # bare probes compare `==` and a reducer would collapse them (`a & b` folds
    # to `a`) — the probes would then measure the reducer's view of them rather
    # than execution order. The node_name breaks that tie.
    def probe(log, marker)
      Plumb::Function.opaque(inspect: "probe:#{marker}") do |result|
        log << marker
        result
      end.as_node(:"probe_#{marker}")
    end

    # A converting step that records that it ran.
    def converting_probe(log, marker, &fn)
      Plumb::Function.opaque(inspect: "convert:#{marker}") do |result|
        log << marker
        result.valid(fn.call(result.value))
      end.as_node(:"convert_#{marker}")
    end

    it 'runs a >> chain left to right' do
      log = []
      type = probe(log, :a) >> probe(log, :b) >> probe(log, :c)
      type.resolve(1)
      expect(log).to eq(%i[a b c])
    end

    it 'runs each converting step exactly once, in order' do
      log = []
      type = converting_probe(log, :inc) { |v| v + 1 } >>
             converting_probe(log, :double) { |v| v * 2 }
      result = type.resolve(1)
      expect(log).to eq(%i[inc double])
      expect(result.value).to eq(4) # (1+1)*2 — not 1+1+1 or (1*2)+1
    end

    it 'stops a >> chain at the first failure' do
      log = []
      type = probe(log, :a) >> Types::Integer >> probe(log, :b)
      type.resolve('not an integer')
      expect(log).to eq(%i[a])
    end

    it 'tries | branches left to right and stops at the first success' do
      log = []
      type = (probe(log, :left) >> Types::Integer) | (probe(log, :right) >> Types::String)
      type.resolve(1)
      expect(log).to eq(%i[left])
    end

    it 'falls through to the right | branch after the left fails' do
      log = []
      type = (probe(log, :left) >> Types::Integer) | (probe(log, :right) >> Types::String)
      type.resolve('a')
      expect(log).to eq(%i[left right])
    end

    it 'runs both sides of an intersection' do
      log = []
      type = probe(log, :a) & probe(log, :b)
      type.resolve(1)
      expect(log).to eq(%i[a b])
    end

    it 'runs a record\'s fields once each' do
      log = []
      type = Types::Hash[a: probe(log, :a) >> Types::Integer, b: probe(log, :b) >> Types::Integer]
      type.resolve({ a: 1, b: 2 })
      expect(log.sort).to eq(%i[a b])
    end

    it 'runs an array element step once per element' do
      log = []
      type = Types::Array[probe(log, :e) >> Types::Integer]
      type.resolve([1, 2, 3])
      expect(log).to eq(%i[e e e])
    end
  end

  # ---------------------------------------------------------------------------
  # 3. AST shape snapshot.  Regenerate DELIBERATELY (see the header).
  # ---------------------------------------------------------------------------
  describe 'AST shape' do
    FIXTURE = ::File.expand_path('fixtures/ast_shapes.yml', __dir__)

    # Anything that may legitimately raise is captured as a string rather than
    # blowing up the snapshot — a change from a value to a raise (or back) is
    # itself a shape change worth seeing in the diff.
    #
    # Normalized before storing: a type built around a block (`#check`, a policy)
    # inspects its Proc, and a struct instance inspects its object_id — both
    # embed a per-process address that would make the snapshot differ on every
    # run. Line numbers inside `#<Proc:0x… spec/…:12>` are kept: they identify
    # WHICH block, which is real shape information.
    def self.capture(&block)
      normalize(block.call.to_s)
    rescue ::StandardError, ::NotImplementedError => e
      "!raises #{e.class}"
    end

    def self.normalize(str)
      str
        .gsub(/0x[0-9a-f]+/, '0xADDR')
        .gsub(/#<([A-Za-z0-9_:]+):\d+ /, '#<\1:ID ')
        .gsub(::File.expand_path('..', __dir__), '.')
    end

    def self.shape_for(type)
      {
        'class' => type.class.name,
        'node_name' => capture { type.node_name },
        'inspect' => capture { type.inspect },
        'input_type' => capture { type.input_type.inspect },
        'output_type' => capture { type.output_type.inspect },
        'value_preserving' => capture { Plumb::Subtyping.value_preserving?(type) },
        'metadata' => capture { type.metadata.inspect },
        'json_schema' => capture { type.to_json_schema.inspect }
      }
    end

    ACTUAL = CORPUS.to_h { |entry| [entry.label, shape_for(entry.type)] }.freeze

    if ENV['REGENERATE_AST_SHAPES']
      it 'regenerates the fixture' do
        ::File.write(FIXTURE, ACTUAL.to_yaml)
        warn "\nREGENERATED #{FIXTURE} — review `git diff` before committing.\n"
      end
    else
      expected = ::File.exist?(FIXTURE) ? ::YAML.unsafe_load_file(FIXTURE) : {}

      it 'has a fixture to compare against' do
        expect(expected).not_to be_empty,
                                'run REGENERATE_AST_SHAPES=1 bundle exec rspec spec/invariants_spec.rb'
      end

      it 'covers exactly the corpus' do
        expect(expected.keys.sort).to eq(ACTUAL.keys.sort)
      end

      ACTUAL.each do |label, shape|
        it label do
          skip 'not in fixture — regenerate' unless expected.key?(label)

          expect(shape).to eq(expected[label])
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Subtyping relation snapshot.
  #
  # The split changes what `<=` answers for converting chains (deliberately —
  # it fixes an unsoundness). Pin the whole relation over a smaller grid so the
  # change is enumerable rather than discovered one spec at a time.
  # ---------------------------------------------------------------------------
  describe 'subtype relation' do
    RELATION_FIXTURE = ::File.expand_path('fixtures/subtype_relation.yml', __dir__)

    GRID = {
      'Any' => Types::Any,
      'Never' => Types::Never,
      'String' => Types::String,
      'Integer' => Types::Integer,
      'Numeric' => Types::Numeric,
      'Integer[0..100]' => Types::Integer[0..100],
      'Integer[10..]' => Types::Integer[10..],
      'String[/a/]' => Types::String[/a/],
      'String.where(size: 1..3)' => Types::String.where(size: 1..3),
      'String|Integer' => Types::String | Types::Integer,
      'String->Integer' => Types::String.transform(::Integer, &:to_i),
      'String >> String->Integer' => Types::String >> Types::String.transform(::Integer, &:to_i),
      'Integer[0..100] & Integer[10..]' => Types::Integer[0..100] & Types::Integer[10..],
      'Array[Integer]' => Types::Array[Types::Integer],
      'Array[Numeric]' => Types::Array[Types::Numeric],
      'Hash[a: Integer]' => Types::Hash[a: Types::Integer],
      'Hash[a: Integer, b: String]' => Types::Hash[a: Types::Integer, b: Types::String]
    }.freeze

    ACTUAL_RELATION = GRID.keys.each_with_object({}) do |a, acc|
      acc[a] = GRID.keys.select { |b| Plumb::Subtyping.subtype?(GRID[a], GRID[b]) }
    end.freeze

    if ENV['REGENERATE_AST_SHAPES']
      it 'regenerates the fixture' do
        ::File.write(RELATION_FIXTURE, ACTUAL_RELATION.to_yaml)
      end
    else
      expected = ::File.exist?(RELATION_FIXTURE) ? ::YAML.unsafe_load_file(RELATION_FIXTURE) : {}

      ACTUAL_RELATION.each do |a, supertypes|
        it "#{a} <= ..." do
          skip 'not in fixture — regenerate' unless expected.key?(a)

          expect(supertypes).to eq(expected[a])
        end
      end
    end

    # These hold regardless of the fixture — they are the lattice laws the
    # refactor must not break.
    it 'is reflexive' do
      GRID.each { |label, type| expect(Plumb::Subtyping.subtype?(type, type)).to be(true), label }
    end

    it 'has Any as top' do
      GRID.each { |label, type| expect(Plumb::Subtyping.subtype?(type, Types::Any)).to be(true), label }
    end

    it 'has Never as bottom' do
      GRID.each { |label, type| expect(Plumb::Subtyping.subtype?(Types::Never, type)).to be(true), label }
    end

    it 'is transitive' do
      keys = GRID.keys
      keys.each do |a|
        keys.each do |b|
          next unless Plumb::Subtyping.subtype?(GRID[a], GRID[b])

          keys.each do |c|
            next unless Plumb::Subtyping.subtype?(GRID[b], GRID[c])

            expect(Plumb::Subtyping.subtype?(GRID[a], GRID[c])).to be(true),
                                                                   "#{a} <= #{b} <= #{c}, but not #{a} <= #{c}"
          end
        end
      end
    end

    # A type may not be a subtype of two PROVABLY DISJOINT types.
    #
    # This currently FAILS, and it is the reason for the refactor: `Subtyping`
    # applies the intersection rule (`(a1 ∧ a2) <= b` if either conjunct is)
    # to every `And`, but an `And` built by `#>>` around a transform is a
    # COMPOSITION, not an intersection — so `String >> (String -> Integer)`
    # reports as a subtype of both String and Integer.
    #
    # Marked pending rather than deleted so it flips to a failure ("expected
    # pending to fail, but it passed") the moment Phase 2 fixes it — at which
    # point remove this marker.
    it 'never places a type under two disjoint types' do
      pending 'fixed by the Compose/Intersection split (Phase 2)'
      disjoint = [%w[String Integer], %w[String Numeric]]
      GRID.each do |label, type|
        disjoint.each do |(x, y)|
          both = Plumb::Subtyping.subtype?(type, GRID[x]) && Plumb::Subtyping.subtype?(type, GRID[y])
          next if type.is_a?(Plumb::NeverClass) # bottom is under everything, legitimately

          expect(both).to be(false), "#{label} is a subtype of both #{x} and #{y}"
        end
      end
    end
  end
end

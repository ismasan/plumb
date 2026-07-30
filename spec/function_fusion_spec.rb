# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Function fusion' do
  STRIP = Types::String.transform(::String, &:strip)
  TO_SYM = Types::String.transform(::Symbol, &:to_sym)

  subject(:fused) { append >> prepend }

  let(:append) { Plumb::Function[String => String] { |r| r.valid(r.value + 'aa') } }
  let(:prepend) { Plumb::Function[String => String] { |r| r.valid('bbbb' + r.value) } }
  let(:int_from_string) { Types::String.transform(::Integer, :to_i) }

  # The two properties Plumb::TypedStep names, so fuse_with can ask about a node's
  # #call instead of testing for its class. Both implementations answer them.
  describe 'the typed-step contract' do
    let(:impl) do
      Class.new do
        include Plumb::Implementation[Types::String => ::Integer]
        private def _call(result) = result.valid(result.value.length)
      end.new
    end

    specify '#checks_output? — does #call end by validating output_type?' do
      expect(append.checks_output?).to be(true)
      expect(Plumb::Function.opaque { |r| r }.checks_output?).to be(false) # GuaranteedFunction
      expect(impl.checks_output?).to be(true)
    end

    specify '#fusable_step? — is #call the canonical mapping, and typed?' do
      expect(append.fusable_step?).to be(true)
      expect(impl.fusable_step?).to be(true)
      expect(Plumb::Function.opaque { |r| r }.fusable_step?).to be(false) # untyped
      expect(Types::String.fusable_step?).to be(false) # not a typed step at all
    end
  end

  it 'fuses two Functions with a provable boundary into a single Function' do
    expect(fused).to be_instance_of(Plumb::Function)
    expect(fused.input_type).to eq(Types::String)
    expect(fused.output_type).to eq(Types::String)
    assert_result(fused.resolve('x'), 'bbbbxaa', true)
  end

  it 'still validates the fused ends' do
    assert_result(fused.resolve(10), 10, false)

    lying = Plumb::Function[String => String] { |r| r.valid(r.value) } \
      >> Plumb::Function[String => Integer] { |r| r.valid(r.value) }

    expect(lying).to be_instance_of(Plumb::Function)
    assert_result(lying.resolve('x'), 'x', false)
  end

  it 'fuses left-to-right across longer chains' do
    third = Plumb::Function[String => String] { |r| r.valid(r.value + 'cc') }
    chain = append >> prepend >> third

    expect(chain).to be_instance_of(Plumb::Function)
    assert_result(chain.resolve('x'), 'bbbbxaacc', true)
  end

  it 'does NOT fuse opaque (untyped) functions' do
    f1 = Plumb::Function[->(r) { r.valid(r.value * 2) }]
    f2 = Plumb::Function[->(r) { r.valid(r.value + 1) }]
    chain = f1 >> f2

    # Fusing would be sound (Any <= Any) but pointless — the only checks dropped
    # are Any no-ops — and it would replace both fns with one composite proc.
    # An opaque function IS a wrapped callable, and callers reach that callable
    # through #fn (see Plumb::Attributes.struct_class), so it must stay intact.
    expect(chain).to be_instance_of(Plumb::And)
    expect(chain.children.map(&:fn)).to eq([f1.fn, f2.fn])
    assert_result(chain.resolve(3), 7, true)
  end

  it 'keeps a wrapped struct class reachable across composition' do
    struct = Class.new do
      include Plumb::Attributes
      attribute :name, Plumb::Types::String
    end
    chain = Plumb::Composable.wrap(struct) >> ->(r) { r.valid(r.value.name.upcase) }

    expect(Plumb::Attributes.struct_class(chain.children.first)).to be(struct)
    assert_result(chain.resolve(name: 'ada'), 'ADA', true)
  end

  it 'short-circuits the fn chain when an fn invalidates' do
    seen = []
    failing = Plumb::Function[String => String] { |r| r.invalid(errors: 'nope') }
    tracking = Plumb::Function[String => String] do |r|
      seen << r.value
      r.valid(r.value)
    end
    chain = failing >> tracking

    expect(chain).to be_instance_of(Plumb::Function)
    expect(chain.resolve('x').valid?).to be(false)
    expect(seen).to be_empty
  end

  it 'fuses through the #/ escape hatch too' do
    chain = append / prepend

    expect(chain).to be_instance_of(Plumb::Function)
    assert_result(chain.resolve('x'), 'bbbbxaa', true)
  end

  it 'keeps Guaranteed-ness from the right side' do
    expect(int_from_string).to be_instance_of(Plumb::GuaranteedFunction)

    chain = append >> int_from_string
    expect(chain).to be_instance_of(Plumb::GuaranteedFunction)
    assert_result(chain.resolve('1'), 1, true)

    back_to_plain = int_from_string >> Plumb::Function[Integer => String] { |r| r.valid(r.value.to_s) }
    expect(back_to_plain).to be_instance_of(Plumb::Function)
    assert_result(back_to_plain.resolve('5'), '5', true)
  end

  it 'survives decoration' do
    decorated = Plumb::Decorator.(fused) { |type| type }

    expect(decorated).to be_instance_of(Plumb::Function)
    assert_result(decorated.resolve('x'), 'bbbbxaa', true)
  end

  describe 'compositions that must NOT fuse' do
    it 'keeps an And when the right input type converts the value' do
      right = Plumb::Function[int_from_string => Integer] { |r| r.valid(r.value + 1) }
      composed = append >> right

      expect(composed).to be_a(Plumb::And)
      # 'x' -> 'xaa' -> coerced by the right's input ('xaa'.to_i => 0) -> 1.
      # A fused chain would have fed the String straight to the fn and raised.
      assert_result(composed.resolve('x'), 1, true)
    end

    it 'keeps an And when the left output type converts the value' do
      left = Plumb::Function[Types::String => int_from_string] { |r| r.valid(r.value) }
      right = Plumb::Function[Integer => Integer] { |r| r.valid(r.value + 1) }
      composed = left >> right

      expect(composed).to be_a(Plumb::And)
      assert_result(composed.resolve('5'), 6, true)
    end

    it 'keeps an And when composition is only valid via accepted-type relaxation' do
      left = Plumb::Function[Types::Any => Types::Hash[flags: Types::String]] do |r|
        r.valid(flags: r.value.to_s)
      end
      right = Plumb::Function[Types::Hash[flags: int_from_string] => Types::Hash[flags: Types::Integer]] do |r|
        r.valid(r.value)
      end
      composed = left >> right

      expect(composed).to be_a(Plumb::And)
      # The right's input check does real per-field work: {flags: '5'} -> {flags: 5}.
      assert_result(composed.resolve(5), { flags: 5 }, true)
    end

    it 'keeps an And around subclasses with custom #call semantics' do
      custom_call = Class.new(Plumb::Function) do
        def call(result) = fn.call(result)
      end.new(Types::String, Types::String, ->(r) { r.valid(r.value.upcase) })

      expect(append >> custom_call).to be_a(Plumb::And)
      expect(custom_call >> prepend).to be_a(Plumb::And)
      assert_result((append >> custom_call).resolve('x'), 'XAA', true)
    end

    it 'excludes a filtered Hash, which runs neither boundary check' do
      filtered = Types::Hash[name: Types::String].filtered
      to_hash = Plumb::Function[Types::Any => Types::Hash[name: Types::String]] { |r| r.valid(name: r.value.to_s) }

      expect(to_hash >> filtered).to be_a(Plumb::And)
      expect(filtered.fusable_step?).to be(false)
    end
  end

  # Eligibility is DERIVED from whether #call was replaced, so a subclass that
  # changes nothing about execution still fuses — and the fused node is rebuilt as
  # a plain Function, since keeping #call says nothing about the constructor.
  describe 'Function subclasses that keep the standard #call' do
    it 'fuses one that only adds behaviour beside #call' do
      subclass = Class.new(Plumb::Function) { def node_name = :custom }
      other = subclass.new(Types::String, Types::String, ->(r) { r.valid("#{r.value}!") })

      expect(append >> other).to be_instance_of(Plumb::Function)
      assert_result((append >> other).resolve('x'), 'xaa!', true)
    end

    it 'fuses one whose constructor differs, without calling it' do
      subclass = Class.new(Plumb::Function) do
        def initialize(suffix) = super(Types::String, Types::String, ->(r) { r.valid(r.value + suffix) })
      end

      expect(append >> subclass.new('?')).to be_instance_of(Plumb::Function)
      assert_result((append >> subclass.new('?')).resolve('x'), 'xaa?', true)
    end
  end

  # `>>` is associative, so `(a >> b) >> c` is `a >> (b >> c)`. Without re-associating,
  # one non-fusable step at the head blocks every later step from ever reducing: a
  # chain guarded by a type gate builds And(gate, step1), and since only
  # Function-to-Function fuses, step2 onwards could never join.
  describe 'associativity: a non-fusable head no longer blocks the tail' do
    let(:strip) { Types::String.transform(::String, &:strip) }
    let(:upcase) { Types::String.transform(::String, &:upcase) }
    let(:length) { Types::String.transform(::Integer, &:length) }

    it 'fuses the tail behind a leading type gate' do
      chain = Types::String >> strip >> upcase

      expect(chain.children.size).to eq(2)
      expect(chain.children.first).to eq(Types::String)
      expect(chain.children.last).to be_a(Plumb::Function) # strip and upcase, fused
      expect(chain.parse('  hi  ')).to eq('HI')
    end

    it 'keeps collapsing as further steps are added' do
      chain = Types::String >> strip >> upcase >> length

      # The head stays a direct child however many steps follow. Unfused this would be
      # a nested And three deep, with the gate buried at the bottom.
      expect(chain.children.first).to eq(Types::String)
      expect(chain.children.size).to eq(2)
      expect(chain.children.last.output_type).to eq(Plumb::Composable.wrap(::Integer))
      expect(chain.parse('  hi  ')).to eq(2)
    end

    it 'fuses behind a refinement head too' do
      chain = Types::String.present >> strip >> upcase

      expect(chain.parse('  hi  ')).to eq('HI')
      expect(chain.resolve('').valid?).to be(false) # the head still gates
    end

    it 'leaves a chain alone when the tail cannot fuse' do
      # A trailing refinement is not a Function, so there is nothing to fuse into. Built
      # with `#/` because narrowing what the chain produces is exactly what `#>>`
      # refuses — that rule is unrelated to fusion.
      chain = (Types::String >> strip) / Types::String[/\A[A-Z]+\z/]

      expect(chain.resolve('  HI  ').valid?).to be(true)
      expect(chain.resolve('  hi  ').valid?).to be(false)
    end

    it 'preserves order and errors through the re-association' do
      chain = Types::String >> strip >> length

      assert_result(chain.resolve('  abc  '), 3, true)
      assert_result(chain.resolve(42), 42, false)
    end
  end

  # A covariant container is a FUNCTOR, so the second functor law holds: mapping `f`
  # then mapping `g` is mapping `f >> g`. The left form traverses twice and builds an
  # intermediate collection; the right traverses once.
  describe 'container fusion (the functor law)' do
    let(:strip) { Types::String.transform(::String, &:strip) }
    let(:to_sym) { Types::String.transform(::Symbol, &:to_sym) }

    {
      'Array' => [-> { Types::Array[STRIP] >> Types::Array[TO_SYM] }, -> { Types::Array[STRIP >> TO_SYM] }],
      'Tuple' => [-> { Types::Tuple[STRIP, STRIP] >> Types::Tuple[TO_SYM, TO_SYM] },
                  -> { Types::Tuple[STRIP >> TO_SYM, STRIP >> TO_SYM] }],
      'HashMap' => [-> { Types::Hash[Types::Symbol, STRIP] >> Types::Hash[Types::Symbol, TO_SYM] },
                    -> { Types::Hash[Types::Symbol, STRIP >> TO_SYM] }],
      'Stream' => [-> { Types::Stream[STRIP] >> Types::Stream[TO_SYM] }, -> { Types::Stream[STRIP >> TO_SYM] }]
    }.each do |label, (two_passes, one_pass)|
      it "fuses two #{label} maps into one" do
        expect(two_passes.call).to eq(one_pass.call)
        expect(two_passes.call).to be_instance_of(one_pass.call.class) # not an And
      end
    end

    # The law is about the mapping; fusion must not disturb validity, value OR the
    # errors. Two passes report stage by stage (a first-stage failure means the second
    # never runs), so the boundary guard below is what keeps the two agreeing.
    it 'is indistinguishable from two passes, including on failures' do
      two = Types::Array[strip] >> Types::Array[to_sym]
      one = Types::Array[strip >> to_sym]

      [[' a ', 'b'], [], ['x'], [1], ['a', 2], [nil]].each do |input|
        a = two.resolve(input)
        b = one.resolve(input)
        expect([a.valid?, a.value, a.errors]).to eq([b.valid?, b.value, b.errors]), "for #{input.inspect}"
      end
    end

    # Fusion carries its own proof rather than trusting the caller's: `#>>` type-checks
    # the containers first but `#/` deliberately does not, and both reach #fuse_with.
    # Without a provable element boundary the right map could reject what the left
    # produced, which is exactly the case where one pass would report errors two
    # passes do not.
    describe 'declines when the element boundary is not provable' do
      it 'does not fuse a narrowing element type' do
        expect(Types::Array[strip] / Types::Array[Types::String[/^a/]]).to be_a(Plumb::Conjunction)
      end

      it 'does not fuse an opaque element check' do
        opaque = Types::Any.check('opaque') { |_v| true }
        expect(Types::Array[strip] / Types::Array[opaque]).to be_a(Plumb::Conjunction)
      end

      it 'does not fuse across different functors' do
        expect(Types::Array[strip] / Types::Stream[to_sym]).to be_a(Plumb::Conjunction)
      end

      it 'does not fuse containers of different arity' do
        expect(Types::Tuple[strip, strip] / Types::Tuple[to_sym]).to be_a(Plumb::Conjunction)
      end
    end
  end

  # BOUNDARY ABSORPTION — the one-sided companion to fusion, for a seam where only
  # one side is a typed step. A typed step runs its boundary types as steps, so a
  # plain type beside one moves into the matching slot instead of standing as its own
  # node. What it buys is that an arbitrary callable keeps the types around it:
  # `Types::Integer >> a_proc >> Types::Float` is one `(Integer -> Float)` node
  # reporting both ends, rather than a three-deep chain reporting `Any`.
  describe 'boundary absorption' do
    let(:double) { ->(r) { r.valid(r.value * 2) } }

    it 'collapses type >> callable >> type into a single typed Function' do
      chain = Types::Integer >> double >> Types::Float

      expect(chain).to be_instance_of(Plumb::Function)
      expect(chain.input_type).to eq(Types::Integer)
      expect(chain.output_type).to eq(Types::Float)
      expect(chain.fn).to be(double)
    end

    it 'runs both checks, and the callable between them' do
      chain = Types::Integer >> ->(r) { r.valid(r.value.to_f) } >> Types::Float

      assert_result(chain.resolve(2), 2.0, true)
      assert_result(chain.resolve('2'), '2', false)  # input check
      assert_result(chain.resolve(2), 2.0, true)

      no_convert = Types::Integer >> double >> Types::Float
      assert_result(no_convert.resolve(2), 4, false) # output check: 4 is not a Float
    end

    # Any Plumb type composes this way, including one that BUILDS a value: a
    # `Types::Data` struct turns a Hash into an instance, and both slots here are
    # no-ops, so it moves into them like any other type.
    it 'collapses a chain around a Types::Data struct' do
      person = Types::Data[name: Types::String]
      renamer = person >> ->(r) { r.valid(r.value.with(name: r.value.name.upcase)) } >> person

      expect(renamer).to be_instance_of(Plumb::Function)
      expect(renamer.input_type).to be(person)
      expect(renamer.output_type).to be(person)
      expect(renamer.parse(name: 'ada').name).to eq('ADA')
      expect(renamer.parse(person.new(name: 'ada')).name).to eq('ADA')
      assert_result(renamer.resolve('nope'), 'nope', false)
      # The struct's own field errors survive the collapse.
      expect(renamer.resolve(name: 42).errors).to eq({ name: 'Must be a String' })
    end

    it 'does not run the callable when the absorbed input check fails' do
      seen = []
      chain = Types::Integer >> ->(r) { seen << r.value; r.valid(r.value) } >> Types::Integer

      expect(chain.resolve('nope').valid?).to be(false)
      expect(seen).to be_empty
    end

    describe 'the input slot' do
      it 'takes a preceding type, leaving the callable reachable' do
        chain = Types::Integer >> double

        expect(chain).to be_instance_of(Plumb::GuaranteedFunction)
        expect(chain.input_type).to eq(Types::Integer)
        expect(chain.output_type).to eq(Types::Any) # the callable's output is unknown
        expect(chain.fn).to be(double)
        expect(chain.wraps_callable?).to be(true)
        assert_result(chain.resolve(2), 4, true)
        assert_result(chain.resolve('x'), 'x', false)
      end

      # Only into an `Any` slot, where no check is dropped. A slot that declares a
      # type is doing work, and absorbing over it is the left-hand gate drop
      # Plumb::Optimizer declines — see the note in its header.
      it 'declines a slot that already declares a type' do
        chain = Types::String >> int_from_string

        expect(chain).to be_a(Plumb::And)
        expect(chain.children).to eq([Types::String, int_from_string])
      end

      # An `Any` slot has no check to drop, so a CONVERTING type is absorbed too — it
      # runs in the slot exactly where the no-op ran. A record still drops undeclared
      # keys before the callable sees the value.
      it 'takes a preceding type that changes the value' do
        chain = Types::Hash[name: Types::String] >> ->(r) { r.valid(r.value.keys) }

        expect(chain).to be_instance_of(Plumb::GuaranteedFunction)
        expect(chain.input_type).to eq(Types::Hash[name: Types::String])
        assert_result(chain.resolve({ name: 'a', x: 1 }), [:name], true)
      end

      # A typed step runs its own fn between its own checks, so a seam between two of
      # them is #fuse_with's; where fusion declines — two opaque wrappers — both nodes
      # stay, keeping each #fn reachable.
      it 'declines a preceding typed step' do
        chain = int_from_string >> ->(r) { r.valid(r.value + 1) }

        expect(chain).to be_a(Plumb::And)
        expect(chain.children.first).to be(int_from_string)
        expect(chain.parse('5')).to eq(6)
      end
    end

    describe 'the output slot' do
      let(:to_numeric) { Plumb::Function[Types::String => Types::Numeric] { |r| r.valid(r.value.to_f) } }

      # Narrowing what a step produces is what `#>>` refuses (Numeric is not a Float),
      # so this is the `#/` case — and the Numeric check goes, since every value the
      # narrower Float admits it admitted too.
      it 'takes a narrower type in place of a checked output' do
        narrowed = to_numeric / Types::Float

        expect(narrowed).to be_instance_of(Plumb::Function)
        expect(narrowed.input_type).to eq(Types::String)
        expect(narrowed.output_type).to eq(Types::Float)
        assert_result(narrowed.resolve('1.5'), 1.5, true)
        assert_result(narrowed.resolve(10), 10, false)
      end

      it 'declines a type the checked output does not cover' do
        expect(to_numeric / Types::Any[::Numeric, ::String]).to be_a(Plumb::Conjunction)
      end

      # `D <= C` alone is not enough to drop C's check: the subtype relation identifies a
      # CONVERTING D by what it PRODUCES, and what matters here is what it ACCEPTS.
      # `Types::Static[10] <= Types::Integer` holds — its value is an Integer — but a
      # Static accepts anything, so taking the slot would swallow the Integer check.
      it 'declines a converting type that would swallow the dropped check' do
        to_int = Plumb::Function[Types::Any => Types::Integer] { |r| r.valid(r.value) }
        static = Types::Static[10]
        expect(Plumb::Subtyping.subtype?(static, Types::Integer)).to be(true)

        chain = to_int >> static

        expect(chain).to be_a(Plumb::And)
        assert_result(chain.resolve('abc'), 'abc', false) # the Integer check still runs
        assert_result(chain.resolve(5), 10, true)
      end

      # An unchecked output is a build-time guarantee (see GuaranteedFunction). When it
      # already implies the type there is nothing to absorb — that redundant gate is
      # reduce_step's to drop, and dropping it keeps the guarantee.
      it 'leaves a guarantee that already implies the type' do
        expect(int_from_string >> Types::Integer).to be(int_from_string)
      end

      it 'declines a step that changes the value, which fusion handles better' do
        chain = (Types::Integer >> double) >> Types::Integer.transform(::String, &:to_s)

        expect(chain).to be_a(Plumb::And)
        expect(chain.parse(2)).to eq('4')
      end
    end

    # Re-association, as for #fuse_with: the boundary a chain presents belongs to the
    # step at that end of it.
    it 'reaches a step behind a leading type gate' do
      to_numeric = Plumb::Function[Types::Numeric => Types::Numeric] { |r| r.valid(r.value.to_f) }
      chain = (Types::Integer >> to_numeric) / Types::Float

      expect(chain).to be_a(Plumb::And)
      expect(chain.children.first).to eq(Types::Integer)
      expect(chain.children.last.output_type).to eq(Types::Float)
      assert_result(chain.resolve(2), 2.0, true)
      assert_result(chain.resolve(2.0), 2.0, false) # the gate runs
    end

    # A labelled function renders as its label instead of its types, so a type
    # absorbed into a slot would disappear from #inspect. Plumb's own wrappers are
    # the labelled ones, and for them the label is the useful reading.
    it 'leaves a labelled function alone' do
      generated = Types::Integer.generate { 10 }

      expect(generated).to be_a(Plumb::And)
      expect(generated.inspect).to include('generator')
      expect(generated.parse).to eq(10)
    end
  end
end

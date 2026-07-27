# frozen_string_literal: true

require 'spec_helper'

module ImplementationSpecTypes
  User = Struct.new(:id, :level)

  UUID = Types::String[/\A[a-f0-9-]{36}\z/]

  # The canonical case: a stateful object, constructed by the user's own
  # #initialize, that behaves like a typed Plumb function.
  class UserFinder
    include Plumb::Implementation[UUID => User]

    def initialize(scope, users = {})
      @scope = scope
      @users = users
    end

    private def _call(result)
      user = @users[result.value]
      return result.invalid(errors: 'no user!') unless user && user.level == @scope

      result.valid(user)
    end
  end

  class Stringifier
    include Plumb::Implementation[User => Types::String]

    private def _call(result) = result.valid(result.value.id)
  end

  class Opaque
    include Plumb::Implementation

    private def _call(result) = result.valid(result.value.to_s)
  end

  # `extend` instead of `include`: the class itself is the step.
  class Downcase
    extend Plumb::Implementation[Types::String => UUID]

    def self._call(result) = result.valid(result.value.downcase)
  end

  ADMIN = User.new('11111111-1111-1111-1111-111111111111', 'admin')
  USERS = { ADMIN.id => ADMIN }.freeze

  RSpec.describe Plumb::Implementation do
    let(:finder) { UserFinder.new('admin', USERS) }

    describe '.[] mixin builder' do
      it 'expects a one-pair Hash' do
        expect { Plumb::Implementation[Types::String] }.to raise_error(ArgumentError, /one-pair Hash/)
        expect { Plumb::Implementation[Types::String => User, Integer => User] }
          .to raise_error(ArgumentError, /one-pair Hash/)
      end

      it 'wraps raw Ruby types' do
        mod = Plumb::Implementation[::String => User]
        klass = Class.new { private def _call(result) = result }
        klass.include(mod)
        expect(klass.new.input_type).to eq(Types::String)
        expect(klass.new.output_type).to eq(Plumb::Composable.wrap(User))
      end

      it 'inspects as the declared pair' do
        expect(Plumb::Implementation[Types::String => Types::Integer].inspect)
          .to eq('Plumb::Implementation[Types::String => Types::Integer]')
      end
    end

    specify 'declared types' do
      expect(finder.input_type).to eq(UUID)
      expect(finder.output_type).to eq(Plumb::Composable.wrap(User))
      expect(finder.children).to eq([UUID, Plumb::Composable.wrap(User)])
      expect(finder.node_name).to eq(:function)
      expect(finder.inspect).to eq(
        'ImplementationSpecTypes::UserFinder' \
        '(Types::String[/\A[a-f0-9-]{36}\z/] -> ImplementationSpecTypes::User)'
      )
    end

    describe '#call and #_call' do
      it 'runs the input check, the class\' #_call, then the output check' do
        assert_result(finder.resolve(ADMIN.id), ADMIN, true)
      end

      it 'rejects invalid input before reaching the class\' #_call' do
        klass = Class.new do
          include Plumb::Implementation[Types::String => Types::String]

          attr_reader :calls

          def initialize = @calls = 0

          private def _call(result)
            @calls += 1
            result
          end
        end
        step = klass.new
        expect(step.resolve(10).valid?).to be(false)
        expect(step.calls).to eq(0)
        expect(step.resolve('ok').valid?).to be(true)
        expect(step.calls).to eq(1)
      end

      it 'keeps the class\' own invalid results' do
        result = finder.resolve('22222222-2222-2222-2222-222222222222')
        expect(result.valid?).to be(false)
        expect(result.errors).to eq('no user!')
      end

      it 'validates the returned value against the output type' do
        klass = Class.new do
          include Plumb::Implementation[Types::String => Types::Integer]
          private def _call(result) = result.valid('not an integer')
        end
        result = klass.new.resolve('foo')
        expect(result.valid?).to be(false)
      end

      it 'coerces through a converting input type' do
        klass = Class.new do
          include Plumb::Implementation[Types::String.transform(::Integer, &:to_i) => Types::Integer]
          private def _call(result) = result.valid(result.value * 2)
        end
        assert_result(klass.new.resolve('21'), 42, true)
      end

      it 'raises a helpful error when the class does not return a Result' do
        klass = Class.new do
          include Plumb::Implementation[Types::String => Types::String]
          private def _call(_result) = 'oops'
        end
        expect { klass.new.resolve('foo') }.to raise_error(Plumb::TypeError, /must return a Plumb::Result/)
      end

      it 'raises NotImplementedError when the class defines no #_call' do
        klass = Class.new { include Plumb::Implementation[Types::String => Types::String] }
        expect { klass.new.resolve('foo') }.to raise_error(NotImplementedError)
      end
    end

    specify '#parse' do
      expect(finder.parse(ADMIN.id)).to eq(ADMIN)
      expect { finder.parse('nope') }.to raise_error(Plumb::ParseError)
    end

    describe 'subtyping' do
      it 'is identified by what it produces' do
        expect(finder <= User).to be(true)
        expect(finder <= Types::Any).to be(true)
        expect(finder <= Types::String).to be(false)
        expect(Plumb::Composable.wrap(User) >= finder).to be(true)
      end

      it 'accepts what its input type accepts' do
        expect(Plumb::Subtyping.accepted_type(finder)).to eq(UUID)
      end
    end

    describe 'composition' do
      it 'composes on the right of a compatible producer' do
        type = Types::String[/\A[a-f0-9-]{36}\z/] >> finder
        assert_result(type.resolve(ADMIN.id), ADMIN, true)
      end

      it 'composes on the left, feeding its output type' do
        type = finder >> Stringifier.new
        assert_result(type.resolve(ADMIN.id), ADMIN.id, true)
      end

      it 'raises when the producer cannot satisfy its input type' do
        expect { Types::Integer >> finder }.to raise_error(Plumb::TypeError, /cannot compose/)
      end

      it 'raises when its output cannot satisfy the consumer' do
        expect { finder >> Types::Integer }.to raise_error(Plumb::TypeError, /cannot compose/)
      end

      it 'opts out of the check when opaque' do
        type = Types::Integer >> Opaque.new >> Types::String
        assert_result(type.resolve(10), '10', true)
      end

      it 'unions' do
        type = finder | Types::String
        assert_result(type.resolve(ADMIN.id), ADMIN, true)
        assert_result(type.resolve('nope'), 'nope', true)
      end

      it 'works as a step in a pipeline' do
        pipe = Types::String.pipeline { |pl| pl.step finder }
        assert_result(pipe.resolve(ADMIN.id), ADMIN, true)
      end

      it 'works as a Hash field' do
        type = Types::Hash[user: finder]
        assert_result(type.resolve(user: ADMIN.id), { user: ADMIN }, true)
      end
    end

    describe 'visitors' do
      specify '#to_json_schema describes the input side' do
        expect(finder.to_json_schema).to eq(
          { 'type' => 'string', 'pattern' => '\\A[a-f0-9-]{36}\\z' }
        )
      end

      specify 'user metadata is collected through the node' do
        expect(finder.metadata).to eq({})
        expect((UUID.metadata(tag: 'id') >> finder).metadata[:tag]).to eq('id')
      end
    end

    describe 'the composable surface' do
      it 'supports #metadata, #not and #transform' do
        expect(finder.metadata(tag: 'finder').metadata[:tag]).to eq('finder')
        assert_result(finder.not.resolve('nope'), 'nope', true)
        assert_result(finder.transform(::String, &:level).resolve(ADMIN.id), 'admin', true)
      end

      it 'lets the class override #node_name' do
        klass = Class.new do
          include Plumb::Implementation[Types::String => Types::String]
          def node_name = :custom
          private def _call(result) = result
        end
        expect(klass.new.node_name).to eq(:custom)
      end
    end

    describe 'subclasses' do
      # #_call is an ordinary method: an override is found by normal lookup and
      # the inherited #call keeps checking around it.
      let(:subclass) do
        Class.new(UserFinder) do
          private def _call(result)
            result.valid(super.value.dup.tap { |u| u.level = 'root' })
          end
        end
      end

      it 'checks around a subclass\' own #_call' do
        finder = subclass.new('admin', USERS)
        expect(finder.parse(ADMIN.id).level).to eq('root')
        expect(finder.resolve(10).valid?).to be(false) # input check
      end

      it 'keeps the output check' do
        klass = Class.new(UserFinder) { private def _call(result) = result.valid('not a user') }
        expect(klass.new('admin', USERS).resolve(ADMIN.id).valid?).to be(false)
      end

      it 'inherits the declared types and composability' do
        finder = subclass.new('admin', USERS)
        expect(finder.input_type).to eq(UUID)
        expect(finder <= User).to be(true)
        expect { Types::Integer >> finder }.to raise_error(Plumb::TypeError)
      end

      it 'lets a subclass redeclare the pair' do
        klass = Class.new(UserFinder) do
          include Plumb::Implementation[UUID => Types::String]
          private def _call(result) = result.valid(super.value.level)
        end
        assert_result(klass.new('admin', USERS).resolve(ADMIN.id), 'admin', true)
      end

      it 'runs the checks once through a super chain' do
        calls = []
        base = Class.new do
          input = Types::String.transform(::String) do |v|
            calls << v
            "#{v}!"
          end
          include Plumb::Implementation[input => Types::String]
          private def _call(result) = result
        end
        sub = Class.new(base) do
          private def _call(result) = super.then { |r| r.valid(r.value.upcase) }
        end
        assert_result(sub.new.resolve('hi'), 'HI!', true)
        expect(calls).to eq(['hi']) # the input transform ran exactly once
      end
    end

    describe 'extend: the class itself is the step' do
      specify 'declared types, on the class' do
        expect(Downcase.input_type).to eq(Types::String)
        expect(Downcase.output_type).to eq(UUID)
        expect(Downcase.children).to eq([Types::String, UUID])
        expect(Downcase.node_name).to eq(:function)
      end

      it 'keeps Ruby\'s own #name, #inspect, #== and #<=' do
        expect(Downcase.name).to eq('ImplementationSpecTypes::Downcase')
        expect(Downcase.inspect).to eq('ImplementationSpecTypes::Downcase')
        # Composable::Equality is NOT installed: a class stays == only to itself
        twin = Class.new { extend Plumb::Implementation[Types::String => UUID] }
        expect(twin == Downcase).to be(false)
        expect(Downcase <= Object).to be(true) # module ancestry, not the type relation
      end

      specify '.call wraps self._call in the declared checks' do
        assert_result(Downcase.resolve(ADMIN.id.upcase), ADMIN.id, true)
        expect(Downcase.resolve(10).valid?).to be(false) # input check
        expect(Downcase.resolve('nope').valid?).to be(false) # output check
        expect(Downcase.parse(ADMIN.id.upcase)).to eq(ADMIN.id)
      end

      it 'composes as a step, on both sides' do
        type = Types::String >> Downcase >> finder
        assert_result(type.resolve(ADMIN.id.upcase), ADMIN, true)
        expect { Types::Integer >> Downcase }.to raise_error(Plumb::TypeError, /cannot compose/)
      end

      it 'is used as a type anywhere a step is expected' do
        assert_result(
          Types::Hash[id: Downcase].resolve(id: ADMIN.id.upcase),
          { id: ADMIN.id },
          true
        )
      end

      specify 'subtyping, asked for explicitly' do
        expect(Plumb::Subtyping.subtype?(Downcase, Types::String)).to be(true)
        expect(Plumb::Subtyping.subtype?(Downcase, Types::Integer)).to be(false)
      end

      specify '#to_json_schema describes the input side' do
        expect(Downcase.to_json_schema).to eq({ 'type' => 'string' })
      end

      it 'raises NotImplementedError when the class defines no self._call' do
        klass = Class.new { extend Plumb::Implementation[Types::String => Types::String] }
        expect { klass.resolve('foo') }.to raise_error(NotImplementedError)
      end

      it 'checks around a subclass\' own self._call' do
        sub = Class.new(Downcase) do
          def self._call(result) = result.valid(result.value.strip.downcase)
        end
        expect(sub.parse("  #{ADMIN.id.upcase}  ")).to eq(ADMIN.id)
        expect(sub.resolve(10).valid?).to be(false) # input check
        expect(sub.resolve('nope').valid?).to be(false) # output check
      end

      it 'supports the opaque form' do
        klass = Class.new do
          extend Plumb::Implementation
          def self._call(result) = result.valid(result.value.to_s)
        end
        type = Types::Integer >> klass >> Types::String
        assert_result(type.resolve(10), '10', true)
      end
    end
  end
end

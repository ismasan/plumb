# frozen_string_literal: true

require 'spec_helper'

module Tests
  class CustomPipeline < Plumb::Pipeline
    attr_reader :input_schema

    def initialize(...)
      @input_schema = Types::Hash
      super
    end

    def input(schema = {})
      schema = Types::Hash[schema]
      @input_schema = schema
      step schema
    end

    private

    def prepare_step(callable)
      @input_schema += callable.input_schema if callable.respond_to?(:input_schema)
      callable
    end
  end

  class WithAround < Plumb::Pipeline
    around do |step, result|
      step.call(result.valid(result.value + 1))
    end
  end

  Multiplier = Data.define(:factor) do
    def call(step, result)
      step.call(result.valid(result.value * factor))
    end
  end

  class WithAroundSub < WithAround
    around Multiplier.new(2)
  end
end

RSpec.describe Plumb::Pipeline do
  specify '#step(output_type, &block) adds a Function step' do
    user = Data.define(:name)
    pipeline = Types::Any.pipeline do |pl|
      pl.step Types::Hash[name: Types::String]
      pl.step(user) { |r| r.valid(user.new(r.value[:name])) }
    end

    expect(pipeline.output_type).to eq(Plumb::Composable.wrap(user))
    result = pipeline.resolve({ name: 'Joe' })
    expect(result.valid?).to be(true)
    expect(result.value).to eq(user.new('Joe'))
    # the declared output type lets the chain keep type-checking from `user`
    expect { pipeline.output_type >> Types::String }.to raise_error(Plumb::TypeError)
  end

  specify '#step is non-strict; #step! type-checks the composition' do
    # #step allows a narrowing — a later step may narrow what an earlier one produced
    expect do
      Types::Any.pipeline do |pl|
        pl.step Types::Hash                       # any hash
        pl.step Types::Hash[name: Types::String]  # narrower — fine, non-strict
      end
    end.not_to raise_error

    # #step! enforces the strict #>> check at build time
    expect do
      Types::Any.pipeline do |pl|
        pl.step! Types::String
        pl.step! Types::Integer                   # a String can never feed an Integer
      end
    end.to raise_error(Plumb::TypeError)
  end

  specify '#around' do
    list = []
    counts = 0
    pipeline = described_class.new do |pl|
      pl.step Types::Lax::String
      pl.around do |step, result|
        list << 'before: %s' % result.value
        result = step.resolve(result)
        list << 'after: %s' % result.value
        result
      end
      pl.step(Types::Any.transform(::String) { |v| "-#{v}-" })
      pl.around do |step, result|
        counts += 1
        step.resolve(result)
      end
      pl.step(Types::Any.transform(::String) { |v| "*#{v}*" })
    end

    assert_result(pipeline.resolve(1), '*-1-*', true)
    expect(list).to eq([
      'before: 1',
      'after: -1-',
      'before: -1-',
      'after: *-1-*'
    ])
    expect(counts).to eq(1)
  end

  describe 'pipeline subclasses' do
    it 'merges #input_schema' do
      pipeline = Tests::CustomPipeline.new do |pl|
        pl.input(
          q?: Types::String,
          currency: Types::String.options(%w[USD EUR]).default('USD')
        )

        # #step is non-strict, so this composes even though step 1's output
        # ({q, currency}) doesn't provide :country — a later step may narrow.
        pl.step(Tests::CustomPipeline.new do |pl2|
          pl2.input(country?: String)
        end)
      end

      expect(pipeline.input_schema._schema.keys.map(&:to_sym)).to eq(%i[q currency country])
    end

    describe 'class level .around' do
      it 'initializes instances with class-level around blocks' do
        pipeline = Tests::WithAround.new do |pl|
          pl.step(->(r) { r })
          pl.step(->(r) { r })
        end
        expect(pipeline.resolve(2).value).to eq(4)
      end

      it 'adds instance-defined around blocks' do
        pipeline = Tests::WithAround.new do |pl|
          pl.around do |step, result|
            step.call(result.valid(result.value * 2))
          end
          pl.step(->(r) { r })
          pl.step(->(r) { r })
        end
        expect(pipeline.resolve(2).value).to eq(14)
      end

      it 'inherits around blocks from parent class' do
        pipeline = Tests::WithAroundSub.new do |pl|
          pl.step(->(r) { r })
        end
        expect(pipeline.resolve(2).value).to eq(6)
      end
    end
  end

  describe '#around' do
    specify 'with block' do
      count = 0
      pipeline = Plumb::Pipeline.new do |pl|
        pl.around do |step, result|
          count += 1
          step.call(result.valid(result.value + count))
        end
        pl.step(->(r) { r })
        pl.step(->(r) { r })
      end

      expect(pipeline.resolve(2).value).to eq(5)
    end

    specify 'with #call(step, result) => result interface' do
      adder = Class.new do
        def initialize(count = 0)
          @count = count
        end

        def call(step, result)
          @count += 1
          step.call(result.valid(result.value + @count))
        end
      end

      pipeline = Plumb::Pipeline.new do |pl|
        pl.around adder.new
        pl.step(->(r) { r })
        pl.step(->(r) { r })
      end

      expect(pipeline.resolve(2).value).to eq(5)
    end
  end

  # A Pipeline is a transparent wrapper around its accumulated composition, so its
  # #children must be that composition. They used to be captured in #initialize
  # before any step had been added, so a Pipeline reported no steps at all.
  describe '#children' do
    let(:pipeline) do
      Plumb::Pipeline.new(type: Types::Integer) { |pl| pl.step(Types::Integer[0..10]) }
    end

    it 'is the accumulated composition, not the starting type' do
      expect(pipeline.children.size).to eq(1)
      expect(pipeline.children.first).not_to eq(Types::Integer)
      expect(pipeline.children.first).to eq(Types::Integer[0..10])
    end

    # Composable#== compares #children, so a stale snapshot made every Pipeline with
    # the same starting type equal regardless of its steps.
    it 'distinguishes pipelines with different steps' do
      other = Plumb::Pipeline.new(type: Types::Integer) { |pl| pl.step(Types::Integer[20..30]) }

      expect(pipeline).not_to eq(other)
      expect(pipeline).to eq(Plumb::Pipeline.new(type: Types::Integer) { |pl| pl.step(Types::Integer[0..10]) })
    end

    # Every visitor walks #children, so the steps were invisible to all of them.
    it 'lets a visitor see the steps' do
      expect(pipeline.to_json_schema).to eq(
        'type' => 'integer', 'minimum' => 0, 'maximum' => 10
      )
    end

    it 'keeps tracking the type when the pipeline is left unfrozen' do
      pl = Plumb::Pipeline.new(type: Types::Integer, freeze_after: false)
      expect(pl.children.first).to eq(Types::Integer)

      pl.step(Types::Integer[0..10])
      expect(pl.children.first).to eq(Types::Integer[0..10])
    end
  end
end

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
end

RSpec.describe Plumb::Pipeline do
  describe 'pipeline subclasses' do
    it 'merges #input_schema' do
      pipeline = Tests::CustomPipeline.new do |pl|
        pl.input(
          q?: Types::String,
          currency: Types::String.options(%w[USD EUR]).default('USD')
        )

        pl.step(Tests::CustomPipeline.new do |pl2|
          pl2.input(country: String)
        end)
      end

      expect(pipeline.input_schema._schema.keys.map(&:to_sym)).to eq(%i[q currency country])
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
end

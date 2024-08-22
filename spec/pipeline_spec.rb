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
end

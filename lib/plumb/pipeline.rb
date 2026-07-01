# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class Pipeline
    include Composable

    class AroundStep
      include Composable

      def initialize(step, block)
        @step = step
        @block = block
      end

      def call(result)
        @block.call(@step, result)
      end

      # Opaque middleware wrapper (its wrapped step may be a plain proc), so its
      # input/output types are unknown — Any (top). Opts out of #>> checks.
      def input_type = Types::Any
      def output_type = Types::Any
    end

    class << self
      def around_blocks
        @around_blocks ||= []
      end

      def around(callable = nil, &block)
        around_blocks << (callable || block)
        self
      end

      def inherited(subclass)
        around_blocks.each { |block| subclass.around(block) }
        super
      end
    end

    attr_reader :children

    def initialize(type: Types::Any, freeze_after: true, &setup)
      @type = type
      @children = [type].freeze
      @around_blocks = self.class.around_blocks.dup

      configure(&setup) if block_given?
      freeze if freeze_after
    end

    def call(result)
      @type.call(result)
    end

    # A Pipeline is a transparent wrapper around its accumulated composition, so
    # it delegates its type-flow to that inner type. When the inner steps are
    # opaque (plain procs/around-wrapped steps) those resolve to Any and the
    # Pipeline still opts out of #>> composition type-checks; when they carry
    # real types, the Pipeline participates accurately.
    def input_type = @type.input_type
    def output_type = @type.output_type

    # Add a step. Two forms:
    #
    #   pl.step(type_or_callable)        # strict #>> chain: type's output must
    #                                    # be acceptable to the next step
    #   pl.step(output_type) { |r| ... } # a Transform: validates the current
    #                                    # output, runs the block, and declares
    #                                    # `output_type` as the produced type
    #
    # The block form builds `Transform(@type, output_type, block)`, so it
    # bypasses the strict composition check (a transform is a trusted, declared
    # conversion) and the rest of the pipeline chains from `output_type`.
    def step(callable = nil, &block)
      if !callable.nil? && block
        @type = Transform.new(@type, Composable.wrap(callable), block)
        return self
      end

      callable ||= block
      unless is_a_step?(callable)
        raise ArgumentError,
              "#step expects an interface #call(Result) Result, but got #{callable.inspect}"
      end

      callable = prepare_step(callable)
      callable = @around_blocks.reverse.reduce(callable) { |cl, bl| AroundStep.new(cl, bl) } if @around_blocks.any?
      @type >>= callable
      self
    end

    def around(callable = nil, &block)
      @around_blocks << (callable || block)
      self
    end

    private

    def configure(&setup)
      case setup.arity
      when 1
        setup.call(self)
      when 0
        instance_eval(&setup)
      else
        raise ArgumentError, 'setup block must have arity of 0 or 1'
      end
    end

    def is_a_step?(callable)
      callable.respond_to?(:call)
    end

    def prepare_step(callable) = callable
  end
end

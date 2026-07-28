# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/disjunction'

module Plumb
  # LEFT-BIASED CHOICE — try `left`, fall back to `right`, built by
  # `Composable#|` when some branch changes the value. The all-branches-preserving
  # case (a genuine set union) is {Plumb::Union}; see {Plumb::Disjunction}.
  #
  # A choice's ends differ, because a converting branch accepts an input the join
  # of the outputs would reject: `Integer | String.transform(:to_i)` consumes
  # `Integer | String` and produces `Integer | Integer`.
  class Or
    include Composable
    include Disjunction

    def initialize(left, right)
      @left = Composable.wrap(left)
      @right = Composable.wrap(right)
      @children = [@left, @right].freeze
      freeze
    end

    # (A | B).output_type == A.output_type | B.output_type. A converting branch
    # produces something other than what it consumed, so this genuinely has to map
    # over the branches — which is exactly what Union does NOT have to do.
    # #input_type is shared with Union; see Disjunction#input_type.
    def output_type
      l = @left.output_type
      r = @right.output_type
      l.equal?(@left) && r.equal?(@right) ? self : Disjunction.build(l, r)
    end

    # A disjunction preserves the value only if EVERY branch does — a branch
    # that transforms (a coercion) changes it when taken. Recurses through the
    # cached accessor so shared subtrees are memoized once.
    #
    # Kept computed rather than hardcoded false: Disjunction.build only routes the
    # converting case here, but `Or.new` remains callable directly (the Decorator
    # rebuilds by class), so an Or may still hold two preserving branches.
    def value_preserving? = children.all? { |c| Plumb::Subtyping.value_preserving?(c) }
  end

  # The computation-AST name for the choice. @see Plumb::Compose
  Choice = Or
end

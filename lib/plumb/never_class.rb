# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  # The bottom type — the dual of AnyClass. No value inhabits it, so it always
  # invalidates. It is produced by a provably-empty intersection (see
  # Composable#& / Subtyping.intersect) and reduces at composition time:
  #   A & Never == Never   (Never dominates the meet)
  #   A | Never == A       (Never is absorbed by the join)
  #   Never >> A == Never
  # As a subtype, Never is below everything: `Never <= X` for all X (its
  # #subtype_of? hook always says yes), and nothing but Never is <= Never.
  class NeverClass
    include Composable

    # Never dominates intersection and short-circuits sequencing/narrowing.
    def &(_other) = self
    def >>(_other) = self
    def /(_other) = self

    # Never is the identity of union: `Never | X == X`.
    def |(other) = Composable.wrap(other)

    def call(result) = result.invalid!(errors: 'no value is allowed (Never)')

    # Bottom is a subtype of every type. The mirror direction (`X <= Never`) is
    # left to the default leaf hook, which is true only reflexively (X == Never).
    def subtype_of?(_other) = true

    # It never succeeds, so it never changes a value — value-preserving like Any,
    # which keeps union absorption uniform.
    def value_preserving? = true
  end
end

# frozen_string_literal: true

module Plumb
  # Internal three-valued result for propositions the type algebra attempts to
  # prove. Unknown is distinct from false so callers cannot turn missing
  # knowledge into an unsafe rewrite.
  class Relation
    class << self
      # Converts a known predicate result to a proof.
      # @param value [Object]
      # @return [Relation]
      def from(value) = value ? PROVEN : DISPROVEN

      # Combines proofs for a logical conjunction.
      # @param relations [Enumerable<Relation>]
      # @return [Relation]
      def all(relations)
        unknown = false
        relations.each do |relation|
          return DISPROVEN if relation.disproven?

          unknown ||= relation.unknown?
        end
        unknown ? UNKNOWN : PROVEN
      end

      # Combines proofs for a logical disjunction.
      # @param relations [Enumerable<Relation>]
      # @return [Relation]
      def any(relations)
        unknown = false
        relations.each do |relation|
          return PROVEN if relation.proven?

          unknown ||= relation.unknown?
        end
        unknown ? UNKNOWN : DISPROVEN
      end

      private :new
    end

    # @return [Boolean]
    def proven? = equal?(PROVEN)

    # @return [Boolean]
    def disproven? = equal?(DISPROVEN)

    # @return [Boolean]
    def unknown? = equal?(UNKNOWN)

    PROVEN = new.freeze
    DISPROVEN = new.freeze
    UNKNOWN = new.freeze
  end
  private_constant :Relation
end

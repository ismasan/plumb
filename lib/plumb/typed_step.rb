# frozen_string_literal: true

module Plumb
  # A TYPED STEP declares an #input_type, an #output_type and a `Result => Result`
  # core, and its #call runs that core between the two checks.
  #
  # Two implementations exist, differing only in WHO OWNS THE STORAGE:
  #
  #   - {Plumb::Function} — Plumb owns the object, so the declared pair and the
  #     callable are ivars behind plain readers.
  #   - {Plumb::Implementation::TypeInterface} — the HOST owns its object and its
  #     constructor, so the pair comes from the declaration and the core is reached
  #     through the host's private #_call.
  #
  # This module holds only what follows from the DECLARATION, and is therefore
  # identical either way. Anything that depends on the storage (#call, #children,
  # #fn, #identity, #==) stays with each implementation, as does #standard_call?.
  #
  # Include AFTER Composable, whose #subtype_identity / #accepted_type defaults
  # these replace.
  module TypedStep
    # Declaring no types at all: both ends are Any (top), so neither check can
    # fail and neither is worth dropping.
    #
    # For a {Plumb::Function} this means more, because every other construction
    # path (#transform, #build, coercions, Encoder.step) declares at least an
    # output type: an opaque Function is exactly the wrapper `Composable.wrap`
    # builds around a bare `#call(Result) => Result` object, and its #fn is that
    # object. Only Function carries that reading — an opaque Implementation IS the
    # object, not a wrapper around one — so callers wanting to unwrap must test for
    # Function too. @see Plumb::Attributes.struct_class, which owns that fact.
    def opaque? = input_type == Types::Any && output_type == Types::Any

    # A conversion is identified for subtyping by what it PRODUCES — the input
    # constraints do not carry through to the output.
    # @see Plumb::Subtyping.subtype?
    def subtype_identity = output_type

    # As a `left >> self` consumer, a step accepts what its INPUT type accepts —
    # not the input node verbatim. When that input is a Hash/container whose fields
    # are themselves converting (eg. a codec's decode schema, whose `flags` field is
    # a `String -> Integer` step), the accepted type is the input relaxed per field
    # to the type it consumes. This is what lets an encode pipeline compose with the
    # matching decode pipeline (`encode >> decode`): both meet at the same input
    # type. Mirrors HashClass#accepted_type.
    def accepted_type = Plumb::Subtyping.accepted_type(input_type)

    # Does #call end by validating against #output_type? True for the plain
    # `input -> fn -> output` mapping; false only where that check is provably
    # redundant (see GuaranteedFunction). This is what tells Function#fuse_with
    # whether a seam has an output check to drop, and whether the node it builds
    # needs to keep one — replacing two `is_a?(GuaranteedFunction)` tests, which
    # gave a non-Function step the right answer only by default.
    #
    # Defaults to true, the fail-safe direction: a wrong `true` keeps a redundant
    # check (slower, still correct), a wrong `false` drops a necessary one.
    def checks_output? = true

    # Can Function#fuse_with drop this node's boundary checks? Only when #call is
    # the canonical mapping for its kind — a node that replaced #call runs
    # different checks, and nothing can be assumed about which of them a seam
    # removes. Excluded when OPAQUE too: the only checks dropped would be no-ops,
    # so there is nothing to win.
    def fusable_step? = !opaque? && standard_call?

    # Is #call still the canonical mapping described above? Only the node can
    # answer, and each implementation answers against its own.
    # @return [Boolean]
    def standard_call?
      raise NotImplementedError, "#{self.class} must define #standard_call?"
    end
  end
end

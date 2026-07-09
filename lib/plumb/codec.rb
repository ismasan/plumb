# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/encoder'

module Plumb
  # A group of {Encoder}s that applies itself to whole types at composition
  # time. A Codec knows nothing about any particular format — only its
  # encoders. Pass-through types are expressed as noop encoders (`.noop`).
  #
  #   class JSONCodec < Plumb::Codec
  #     noop Types::String, Types::Integer, Types::Float, Types::Numeric,
  #          Types::True, Types::False, Types::Nil, Types::Hash, Types::Array
  #
  #     encoder JSONDateRangeEncoder    # Hash[from: Date, to: Date] <=> DateRange
  #     encoder ISODateEncoder          # String <=> Date
  #   end
  #
  #   JSONPerson = JSONCodec >> Person  # decode: wire structures -> Person
  #   WirePerson = Person >> JSONCodec  # encode: Person -> wire structures
  #
  # Composing rewrites the type deeply: every field (at any depth) whose type
  # matches an encoder's output (internal) type is replaced with the oriented
  # {Encoder::Step}; noop-matched types pass through unchanged; anything else
  # raises Plumb::TypeError at composition time, naming the field path. An
  # encoder's wire (input) type is itself rewritten through the same codec, so
  # nested non-native values resolve via other encoders in the group.
  #
  # The Codec leaves no runtime node behind — the result is ordinary Plumb
  # algebra, so parsing, subtyping and visitors work on it unchanged. It works
  # on any type, not just Hash schemas: `JSONCodec >> Types::Date` returns the
  # matched encoder's decode step.
  class Codec
    include Composable

    class << self
      # Register one or more Encoder subclasses, in matching-priority order.
      # The registry is inheritable: subclassing a codec extends it, and a
      # subclass's encoders take precedence over inherited ones when their
      # types are equivalent.
      def encoder(*encoder_classes)
        encoder_classes.each do |enc|
          unless enc.is_a?(::Class) && enc < Encoder
            raise ArgumentError, "expected an Encoder subclass, got #{enc.inspect}"
          end

          own_encoders << enc
        end
        self
      end

      # Register pass-through types: values of these types are already valid in
      # the codec's target format and are left untouched. Implemented as noop
      # encoders (identity #encode/#decode), so they participate in matching
      # like any encoder but rewrite to nothing.
      def noop(*types)
        types.each do |t|
          t = Composable.wrap(t)
          own_encoders << build_noop(t)
        end
        self
      end

      # All registered encoders, inherited first, own last (later registrations
      # win ties in matching).
      def encoders
        inherited = superclass.respond_to?(:encoders) ? superclass.encoders : BLANK_ARRAY
        inherited + own_encoders
      end

      # Class-level composition delegates to a memoized instance, so a Codec
      # subclass composes directly: `JSONCodec >> Person`.
      def instance = @instance ||= new
      def >>(other) = instance >> other
      def |(other) = instance | other
      def &(other) = instance & other
      def for(type) = instance.for(type)
      def to_plumb_type(op:, left:) = instance.to_plumb_type(op:, left:)
      def call(result) = instance.call(result)

      private

      def own_encoders = @own_encoders ||= []

      def build_noop(type)
        Class.new(Encoder[type => type]) do
          def encode(value) = value
          def decode(value) = value

          define_singleton_method(:noop?) { true }
          define_singleton_method(:inspect) { "Noop(#{type.inspect})" }
        end
      end
    end

    attr_reader :encoders

    # @param extra_encoders [Array<Class>] encoders for this instance, appended
    #   after (and winning ties over) the class-level registry.
    def initialize(*extra_encoders)
      @encoders = self.class.encoders + extra_encoders
      @noop_union = @encoders.select(&:noop?).map(&:output_type).reduce { |a, b| Or.new(a, b) }
      freeze
    end

    # Decode direction: rewrite `other` so it accepts wire input and produces
    # the internal values `other` describes. The rewritten type REPLACES the
    # composition — no codec node remains.
    def >>(other)
      Rewriter.new(self, :decode).call(Composable.wrap(other))
    end

    # Both directions for a type, as a [decoding, encoding] pair:
    #
    #   decoder, encoder = Plumb::Codec::JSON.for(Person)
    #   decoder.parse(wire_data)  # => a Person hash
    #   encoder.parse(person)     # => wire structures
    #
    # @param type [Composable, Object]
    # @return [Array(Composable, Composable)]
    def for(type)
      type = Composable.wrap(type)
      [self >> type, type >> self]
    end

    # Encode direction, reached when the codec is the RIGHT operand
    # (`Person >> JSONCodec` — see Composable#to_plumb_type): build an encode
    # rewrite of what `left` produces. Composable#>> then composes
    # `And(left, rewrite)`: the left validates internal input once, the
    # rewrite encodes. Building from `left`'s OUTPUT (not `left` itself)
    # avoids re-running its coercions on already-parsed values.
    def to_plumb_type(op:, left:)
      unless op == :>>
        raise Plumb::TypeError, "#{inspect} only composes with #>> (got #{op}); a Codec is not a value type"
      end

      Rewriter.new(self, :encode).call(Plumb::Subtyping.resolved_output(Composable.wrap(left)))
    end

    def |(_other) = raise Plumb::TypeError, "#{inspect} only composes with #>>; a Codec is not a value type"
    alias & |

    def call(_result)
      raise Plumb::TypeError, "#{inspect} is not a runtime type; compose it with a type via #>>"
    end

    # The best matching REAL (non-noop) encoder for `type`, or nil. Matching is
    # against each encoder's output (internal) type — schemas are written in
    # internal terms in both directions. Most-specific wins; equivalent types
    # tie-break to the last registered; incomparable multi-matches raise.
    def encoder_for(type, path = BLANK_ARRAY)
      matches = encoders.reject(&:noop?).select { |e| Plumb::Subtyping.subtype?(type, e.output_type) }
      return nil if matches.empty?
      return matches.first if matches.size == 1

      minimal = matches.reject do |e|
        # e is dominated when another match's output type is strictly narrower.
        matches.any? do |o|
          !o.equal?(e) &&
            Plumb::Subtyping.subtype?(o.output_type, e.output_type) &&
            !Plumb::Subtyping.subtype?(e.output_type, o.output_type)
        end
      end

      first = minimal.first
      equivalent = minimal.all? do |e|
        Plumb::Subtyping.subtype?(e.output_type, first.output_type) &&
          Plumb::Subtyping.subtype?(first.output_type, e.output_type)
      end
      unless equivalent
        raise Plumb::TypeError,
              "#{inspect}: #{at_path(path)} (#{type.inspect}) matches multiple incomparable encoders: " \
              "#{minimal.map(&:inspect).join(', ')}. Register a more specific encoder or restructure."
      end

      minimal.last
    end

    # Is `type` (one side of it, per direction) covered by the registered noop
    # types? Decode checks what the type ACCEPTS (it will be fed raw wire
    # data); encode checks what it PRODUCES (its output lands in the wire
    # document).
    def noop?(type, direction)
      return false unless @noop_union

      # A Static ignores its input (it reports Any as accepted), so it is
      # judged by what it emits in both directions — eg. the `Static['x']`
      # inside a `.default('x')` composition.
      side = if direction == :encode || type.is_a?(StaticClass)
               Plumb::Subtyping.resolved_output(type)
             else
               Plumb::Subtyping.accepted_type(type)
             end
      Plumb::Subtyping.subtype?(side, @noop_union)
    end

    def at_path(path) = path.empty? ? 'the root type' : "field `#{path.join('.')}`"

    private def _inspect
      "#{self.class == Codec ? 'Plumb::Codec' : self.class.name}[#{encoders.reject(&:noop?).map(&:inspect).join(', ')}]"
    end

    # The deep rewrite walker. Top-down, per node:
    #
    #   1. a real encoder match replaces the node whole (its wire type is
    #      recursively rewritten through the same codec, cycle-guarded);
    #   2. structured composites (Hash schemas, typed Arrays/Tuples/HashMaps,
    #      Or branches, transparent wrappers) recurse into their children —
    #      AFTER encoder matching, so an encoder can target a specific
    #      composite shape, but BEFORE the noop check, so a generic
    #      `noop Types::Hash` can't swallow a structured schema;
    #   3. leaves pass through when noop-covered, otherwise raise with the
    #      dotted field path.
    #
    # Untouched subtrees keep their identity (the original node is returned),
    # so noop pass-through adds no nodes.
    class Rewriter
      def initialize(codec, direction)
        @codec = codec
        @direction = direction # :decode | :encode
        @deferred_memo = {}.compare_by_identity
        @wire_stack = []
        @root = nil
      end

      def call(type)
        @root = type
        visit(type, BLANK_ARRAY)
      end

      private

      # Pure value-preserving refinements carry no data of their own — as
      # children of an And chain they filter the adjacent type's values and
      # pass through the rewrite untouched.
      PURE_REFINEMENTS = %i[constraint attribute_value_match value not].freeze

      def visit(type, path)
        return visit_deferred(type, path) if type.is_a?(Deferred)

        if (enc = @codec.encoder_for(type, path))
          return replace(type, enc, path)
        end

        case type
        when HashClass then visit_hash(type, path)
        when ArrayClass, StreamClass then visit_array(type, path)
        when TupleClass then visit_tuple(type, path)
        when HashMap then visit_hash_map(type, path)
        when Or then visit_or(type, path)
        when And then visit_and(type, path)
        when Metadata then rebuild(type, visit(type.type, path)) { |t| Metadata.new(t, type.metadata) }
        when Policy then rebuild(type, visit(type.children.first, path)) { |t| Policy.new(type.policy_name, type.arg, t) }
        when Composable::Node then rebuild(type, visit(type.type, path)) { |t| t.as_node(type.node_name, type.args) }
        else
          noop_or_fail(type, path)
        end
      end

      # Replace a matched type with the oriented Step. The encoder's wire
      # (input) type is itself rewritten through this codec — that's what lets
      # `Hash[from: Date, to: Date]` resolve its Dates via a String<=>Date
      # encoder in the same group. The rewritten wire type (and, when the
      # matched type is a value-preserving strict subtype of the encoder's
      # output, the narrowed type) are spliced into the Step, so each rewritten
      # field stays a single node.
      def replace(type, enc, path)
        if @wire_stack.include?(enc)
          raise Plumb::TypeError,
                "#{@codec.inspect}: encoder wire-type cycle: #{(@wire_stack + [enc]).map(&:inspect).join(' -> ')}"
        end

        wire = enc.input_type
        begin
          @wire_stack.push(enc)
          rewritten_wire = visit(wire, path + ["<#{enc.inspect} wire>"])
        ensure
          @wire_stack.pop
        end

        narrowed = narrowed_side(type, enc)
        if @direction == :decode
          Encoder::Step.new(enc, :decode,
                            input_type: (rewritten_wire unless rewritten_wire.equal?(wire)),
                            output_type: narrowed)
        else
          Encoder::Step.new(enc, :encode,
                            input_type: narrowed,
                            output_type: (rewritten_wire unless rewritten_wire.equal?(wire)))
        end
      end

      # When the matched type is strictly narrower than the encoder's declared
      # output AND is a pure filter, keep it as the internal-side check (decode
      # re-validates the produced value against it; encode validates the input
      # against it). A value-CONVERTING narrower type is dropped — re-running
      # its conversion on an already-internal value would be wrong; the
      # encoder's declared type stands in.
      def narrowed_side(type, enc)
        internal = enc.output_type
        return nil if type == internal
        return nil unless Plumb::Subtyping.value_preserving?(type)
        return nil unless Plumb::Subtyping.subtype?(type, internal) && !Plumb::Subtyping.subtype?(internal, type)

        type
      end

      def visit_hash(type, path)
        return noop_or_fail(type, path) if type._schema.empty? # the bare "any Hash" — a leaf

        changed = false
        schema = type._schema.each_with_object({}) do |(key, field), h|
          seg = key.literal? ? key.to_s : key.inspect
          v = visit(field, path + [seg])
          changed ||= !v.equal?(field)
          h[key] = v
        end
        changed ? type.class.new(schema:) : type
      end

      def visit_array(type, path)
        element = type.children.first
        return noop_or_fail(type, path) if element.is_a?(AnyClass) # untyped Array — a leaf

        v = visit(element, path + ['[]'])
        v.equal?(element) ? type : type.class.new(element_type: v)
      end

      def visit_tuple(type, path)
        members = type.children.each_with_index.map { |m, i| visit(m, path + ["[#{i}]"]) }
        members.zip(type.children).all? { |v, m| v.equal?(m) } ? type : type.class.new(*members)
      end

      # Keys are left untouched — key normalization (eg. string keys from the
      # wire) is a separate concern (see Types::SymbolizedHash / #symbolized).
      def visit_hash_map(type, path)
        key_type, value_type = type.children
        v = visit(value_type, path + ['{}'])
        v.equal?(value_type) ? type : HashMap.new(key_type, v)
      end

      def visit_or(type, path)
        left, right = type.children
        l = visit(left, path)
        r = visit(right, path)
        l.equal?(left) && r.equal?(right) ? type : Or.new(l, r)
      end

      # An And chain (refinement/sequence) that wasn't matched whole: rewrite
      # the data-bearing children; pure refinements (checks, #where clauses,
      # value matchers) filter the adjacent type's values and pass through.
      def visit_and(type, path)
        left, right = type.children
        l = visit_and_child(left, path)
        r = visit_and_child(right, path)
        l.equal?(left) && r.equal?(right) ? type : And.new(l, r)
      end

      def visit_and_child(child, path)
        return child if child.respond_to?(:node_name) && PURE_REFINEMENTS.include?(child.node_name)

        visit(child, path)
      end

      # Recursive/self-referential types rewrite lazily: the memo ties the knot
      # (all references to one Deferred share one rewritten Deferred), and any
      # unmatched-type error inside the body surfaces at first resolution.
      def visit_deferred(type, path)
        @deferred_memo[type] ||= Deferred.new(-> { visit(type.type, path) })
      end

      def noop_or_fail(type, path)
        if @codec.noop?(type, @direction)
          return type if @direction == :decode

          # Encode: the value at this position is the type's OUTPUT — pass
          # that through, so a coercion field is not re-run on parsed values.
          out = Plumb::Subtyping.resolved_output(type)
          out.equal?(type) ? type : out
        else
          raise Plumb::TypeError,
                "cannot apply #{@codec.inspect} (#{@direction}) to #{@root.inspect}: " \
                "#{@codec.at_path(path)} (#{type.inspect}) matches no encoder and is not covered by its noop types. " \
                'Register an encoder for it, or declare it with .noop.'
        end
      end

      def rebuild(original, visited_inner)
        visited_inner.equal?(original_inner(original)) ? original : yield(visited_inner)
      end

      def original_inner(node)
        node.respond_to?(:type) ? node.type : node.children.first
      end
    end

    # Date <=> ISO 8601 date string ("2024-01-30"). Included in Codec::JSON;
    # its wire type carries `format: 'date'` metadata, so generated JSON
    # Schemas describe date fields as `{type: "string", format: "date"}`.
    class JSONDateEncoder < Encoder[Types::String[/\A\d{4}-\d{2}-\d{2}\z/].metadata(format: 'date') => Types::Date]
      def encode(date) = date.iso8601
      def decode(str) = ::Date.parse(str)
    end

    # A base codec for JSON-like targets: the scalars native to JSON pass
    # through (structured containers are handled structurally by the rewrite;
    # the bare Hash/Array tops cover untyped ones), and Dates map to ISO 8601
    # strings. Subclass it and register encoders:
    #
    #   class MyCodec < Plumb::Codec::JSON
    #     encoder MoneyEncoder
    #   end
    #
    # A subclass encoder for an equivalent type (eg. its own Date encoder)
    # takes precedence over the built-in one.
    class JSON < self
      noop Types::String, Types::Numeric, Types::Integer, Types::Float,
           Types::True, Types::False, Types::Nil,
           Types::Hash, Types::Array

      encoder JSONDateEncoder
    end
  end
end

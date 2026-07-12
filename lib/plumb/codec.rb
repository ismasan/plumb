# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/encoder'

module Plumb
  # A group of {Encoder}s that applies itself to whole types at composition
  # time. A Codec knows nothing about any particular format — only its
  # encoders, plus a list of pass-through types (`.noop`) already valid in
  # the target format.
  #
  #   class JSONCodec < Plumb::Codec
  #     noop Types::String, Types::Integer, Types::Float, Types::Numeric,
  #          Types::True, Types::False, Types::Nil, Types::Hash, Types::Array
  #
  #     encoder JSONDateRangeEncoder    # Hash[from: Date, to: Date] <=> DateRange
  #     encoder ISODateEncoder          # String <=> Date
  #   end
  #
  #   JSONPerson    = JSONCodec >> Person  # decode: input structures -> Person
  #   EncodedPerson = Person >> JSONCodec  # encode: Person -> output structures
  #
  # Composing rewrites the type deeply: every field (at any depth) whose type
  # matches an encoder's output type is replaced with the oriented
  # encoder step (a plain Function, see Encoder.step); noop-matched types
  # pass through unchanged; anything else
  # raises Plumb::TypeError at composition time, naming the field path. An
  # encoder's input type is itself rewritten through the same codec, so
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

      # Register pass-through types: values of these types are already valid
      # in the codec's target format and are left untouched — they rewrite to
      # nothing. Real encoders always match first, so a noop never shadows a
      # registered encoder for the same type.
      def noop(*types)
        types.each { |t| own_noop_types << Composable.wrap(t) }
        self
      end

      # All registered encoders, inherited first, own last (later registrations
      # win ties in matching).
      def encoders
        inherited = superclass.respond_to?(:encoders) ? superclass.encoders : BLANK_ARRAY
        inherited + own_encoders
      end

      # All registered pass-through types, inherited first.
      def noop_types
        inherited = superclass.respond_to?(:noop_types) ? superclass.noop_types : BLANK_ARRAY
        inherited + own_noop_types
      end

      # Class-level composition delegates to a memoized instance, so a Codec
      # subclass composes directly: `JSONCodec >> Person`.
      def instance = @instance ||= new
      def >>(other) = instance >> other
      def |(other) = instance | other
      def &(other) = instance & other
      def for(type) = instance.for(type)
      def to_plumb_type(op:, left:) = instance.to_plumb_type(op:, left:)
      def to_composable = instance
      def call(result) = instance.call(result)

      private

      def own_encoders = @own_encoders ||= []
      def own_noop_types = @own_noop_types ||= []
    end

    attr_reader :encoders, :noop_types

    # @param extra_encoders [Array<Class>] encoders for this instance, appended
    #   after (and winning ties over) the class-level registry.
    def initialize(*extra_encoders)
      @encoders = self.class.encoders + extra_encoders
      @noop_types = self.class.noop_types
      @noop_union = @noop_types.reduce { |a, b| Or.new(a, b) }
      freeze
    end

    # Decode direction: rewrite `other` so it accepts the encoders' input form
    # and produces the output values `other` describes. The rewritten type
    # REPLACES the composition — no codec node remains.
    def >>(other)
      Rewriter.new(self, :decode).call(Composable.wrap(other))
    end

    # Both directions for a type, as a [decoding, encoding] pair:
    #
    #   decoder, encoder = Plumb::Codec::JSON.for(Person)
    #   decoder.parse(input_data) # => a Person hash
    #   encoder.parse(person)     # => output structures
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
    # `And(left, rewrite)`: the left validates its input once, the
    # rewrite encodes. Building from `left`'s OUTPUT (not `left` itself)
    # avoids re-running its coercions on already-parsed values.
    def to_plumb_type(op:, left:)
      unless op == :>>
        raise Plumb::TypeError, "#{inspect} only composes with #>> (got #{op}); a Codec is not a value type"
      end

      left = Composable.wrap(left)
      # A plain-include struct wraps as an opaque Step (output Any), so its
      # rewrite target is the struct node itself, not its resolved output.
      target = Plumb::Attributes.struct_class(left) ? left : Plumb::Subtyping.resolved_output(left)
      Rewriter.new(self, :encode).call(target)
    end

    def |(_other) = raise Plumb::TypeError, "#{inspect} only composes with #>>; a Codec is not a value type"
    alias & |

    def call(_result)
      raise Plumb::TypeError, "#{inspect} is not a runtime type; compose it with a type via #>>"
    end

    # The best matching encoder for `type`, or nil. Matching is against each
    # encoder's output type — schemas are written in output
    # terms in both directions. Most-specific wins; equivalent types
    # tie-break to the last registered; incomparable multi-matches raise.
    def encoder_for(type, path = BLANK_ARRAY)
      matches = encoders.select { |e| Plumb::Subtyping.subtype?(type, e.output_type) }
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
    # types? Decode checks what the type ACCEPTS (it will be fed raw input
    # data); encode checks what it PRODUCES (its output lands in the encoded
    # document).
    def noop?(type, direction)
      return false unless @noop_union

      side = direction == :decode ? Plumb::Subtyping.accepted_type(type) : Plumb::Subtyping.resolved_output(type)
      # A pure filter with an opaque side is judged by the type itself: a
      # bare-matcher Constraint (a branch of a factored refinement union, eg.
      # the `String[/\Atrue\z/i] | String['1']` boolean input type) reports Any
      # as its accepted type, but as a value-preserving refinement it IS its
      # own honest description.
      side = type if side.is_a?(AnyClass) && Plumb::Subtyping.value_preserving?(type)
      Plumb::Subtyping.subtype?(side, @noop_union)
    end

    # Is this concrete VALUE covered by the noop types? Used for Static nodes,
    # whose fixed value can be validated directly — subtyping over the node
    # can't relate an atomic Static to a container noop (`Static[[]]` vs
    # `Types::Array`), but the value itself can just be checked.
    def noop_value?(value)
      return false unless @noop_union

      @noop_union === value
    end

    def at_path(path) = path.empty? ? 'the root type' : "field `#{path.join('.')}`"

    private def _inspect
      "#{self.class == Codec ? 'Plumb::Codec' : self.class.name}[#{encoders.map(&:inspect).join(', ')}]"
    end

    # The deep rewrite walker. Top-down, per node:
    #
    #   1. Static values, Or/And chains and transparent wrappers recurse into
    #      their parts first — they can carry generator machinery (a
    #      `.default`'s `Undefined >> Static` guard) that a wholesale
    #      replacement would drop (see #visit);
    #   2. a real encoder match replaces the node whole (its input type is
    #      recursively rewritten through the same codec, cycle-guarded);
    #   3. structured composites (Hash schemas, typed Arrays/Tuples/HashMaps)
    #      recurse into their children — AFTER encoder matching, so an encoder
    #      can target a specific composite shape, but BEFORE the noop check,
    #      so a generic `noop Types::Hash` can't swallow a structured schema;
    #   4. leaves pass through when noop-covered, otherwise raise with the
    #      dotted field path.
    #
    # Untouched subtrees keep their identity (the original node is returned),
    # so noop pass-through adds no nodes.
    class Rewriter
      def initialize(codec, direction)
        @codec = codec
        @direction = direction # :decode | :encode
        @deferred_memo = {}.compare_by_identity
        @input_memo = {}.compare_by_identity
        @input_stack = []
        @root = nil
      end

      def call(type)
        @root = type
        visit(type, BLANK_ARRAY)
      end

      private

      def visit(type, path)
        return visit_deferred(type, path) if type.is_a?(Deferred)
        # Before encoder matching: a Static's fixed value would otherwise
        # match an encoder atomically (`Static[a_date]` is a subtype of Date)
        # and get replaced by a step that expects encoded input, losing the
        # static behaviour (eg. the default value in a `.default(...)`).
        return visit_static(type, path) if type.is_a?(StaticClass)

        # Or/And chains and transparent wrappers also recurse BEFORE encoder
        # matching: they can carry generator guards (`(Undefined >> Static) |
        # T`, the #default shape) that are subtype-wise invisible — the whole
        # composition IS a subtype of T — but would be dropped by a wholesale
        # replacement. Recursing rewrites the data-bearing parts and keeps the
        # machinery; an encoder with a union output type still matches at
        # branch level. Untouched subtrees come back identical, so there is
        # no shortcut to take here — a whole-composite noop check would let a
        # container-top noop (`noop Types::Array`) swallow a rewritable union
        # (`Array[Date] | String`).
        case type
        when Or then return visit_or(type, path)
        when And then return visit_and(type, path)
        when Metadata then return rebuild(type, type.type, path) { |t| Metadata.new(t, type.metadata) }
        when Policy then return rebuild(type, type.children.first, path) { |t| Policy.new(type.policy_name, type.arg, t) }
        when Composable::Node then return rebuild(type, type.type, path) { |t| t.as_node(type.node_name, type.args) }
        end

        if (enc = @codec.encoder_for(type, path))
          # An encoder whose own input type contains its output type re-matches
          # here while we rewrite that input (enc is on the stack). If that
          # output is noop-covered it's a literal acceptance, not a recursive
          # encoding — leave it (eg. Forms' NilEncoder input `String[''] | Nil`,
          # so a nullable field decodes a literal nil). Otherwise replace()
          # raises the genuine input-type cycle.
          return type if @input_stack.include?(enc) && @codec.noop?(type, @direction)

          return replace(type, enc, path)
        end

        case type
        when HashClass then visit_hash(type, path)
        when ArrayClass, StreamClass then visit_array(type, path)
        when TupleClass then visit_tuple(type, path)
        when HashMap then visit_hash_map(type, path)
        when TaggedHash then visit_tagged_hash(type, path)
        else
          if (struct = Plumb::Attributes.struct_class(type))
            visit_struct(type, struct, path)
          else
            noop_or_fail(type, path)
          end
        end
      end

      # A struct (Types::Data / Plumb::Attributes) is a Hash schema plus a
      # constructor. Decoding, the rewritten schema turns input fields into
      # output values and the class itself builds the instance (Function's
      # output stage CALLS it). Encoding, the class validates/constructs the
      # instance, `#attributes` exposes the output values (shallow — nested
      # structs stay instances and are handled by their own rewritten nodes,
      # unlike the deep #to_h), and the encode-rewritten schema turns them
      # into input values. Either way a single Function node, so accepted/
      # produced types and the JSON Schema stay honest.
      def visit_struct(original, struct, path)
        schema = visit(struct._schema, path)
        if @direction == :decode
          # All fields input-native already: the struct validates and
          # constructs by itself.
          return original if schema.equal?(struct._schema)

          Function.new(schema, struct, Plumb::NOOP)
        else
          Function.new(struct, schema, ->(result) { result.valid!(result.value.attributes) })
        end
      end

      # A Static ignores its input and emits a fixed value (eg. the default in
      # a `.default(...)` composition). Decoding, that value is part of the
      # output structure the schema declares — keep it as-is.
      #
      # Encoding is different: the suffix runs on values the schema has
      # ALREADY produced (the Static ran when the schema did), and
      # resolved_output collapses the `Undefined >> Static` guard of a
      # #default, leaving the Static as an always-matching first Or branch —
      # re-running it would clobber the actual value with the default. So on
      # encode a Static becomes a CHECKED value: match the static value
      # (against the VALUE, not the node — subtyping can't relate an atomic
      # Static to a container noop), then emit its input form — the value
      # itself when noop-covered, or its encoding, computed once here at
      # composition time (the value is fixed, so its encoding is too).
      def visit_static(type, path)
        return type if @direction == :decode

        value = type.children.first
        # Encoder match FIRST, then noop — mirrors the invariant that real
        # encoders always take precedence over pass-through types. Otherwise a
        # static default whose value happens to satisfy a broad noop (eg. a
        # BigDecimal under the Numeric noop) would emit raw instead of encoding.
        if (enc = @codec.encoder_for(type, path))
          encoded = replace(type, enc, path).parse(value)
          And.new(ValueClass.new(value), StaticClass.new(encoded.freeze))
        elsif @codec.noop_value?(value)
          ValueClass.new(value)
        else
          noop_or_fail(type, path)
        end
      end

      # Replace a matched type with the oriented Step. The encoder's input
      # type is itself rewritten through this codec — that's what lets
      # `Hash[from: Date, to: Date]` resolve its Dates via a String<=>Date
      # encoder in the same group. The rewritten input type (and, when the
      # matched type is a value-preserving strict subtype of the encoder's
      # output, the narrowed type) are spliced into the Step, so each rewritten
      # field stays a single node.
      def replace(type, enc, path)
        if @input_stack.include?(enc)
          raise Plumb::TypeError,
                "#{@codec.inspect}: encoder input-type cycle: #{(@input_stack + [enc]).map(&:inspect).join(' -> ')}"
        end

        # A generic encoder builds its input from the matched type (see
        # Encoder.input_type_for), so the input — and its rewrite — vary per
        # matched type, NOT per encoder: memoize by matched type (direction is
        # fixed per Rewriter; the path only feeds error text on the first
        # visit). Fields sharing a type object (eg. the same `Types::Date`
        # constant) still rewrite their input once.
        input = enc.input_type_for(type)
        rewritten_input = @input_memo.fetch(type) do
          begin
            @input_stack.push(enc)
            @input_memo[type] = visit(input, path + ["<#{enc.inspect} input>"])
          ensure
            @input_stack.pop
          end
        end

        # Splice the input into the step unless it is the encoder's declared
        # input type unchanged (then the base step already carries it). A
        # generic encoder's member-specialized input is never that base type, so
        # it is always spliced — the step reports the specific input, not the top.
        input_arg = rewritten_input.equal?(enc.input_type) ? nil : rewritten_input
        narrowed = narrowed_side(type, enc)
        if @direction == :decode
          enc.step(:decode, input_type: input_arg, output_type: narrowed)
        else
          enc.step(:encode, input_type: narrowed, output_type: input_arg)
        end
      end

      # When the matched type is strictly narrower than the encoder's declared
      # output AND is a pure filter, keep it as the output-side check (decode
      # re-validates the produced value against it; encode validates the input
      # against it). A value-CONVERTING narrower type is dropped — re-running
      # its conversion on an already-decoded value would be wrong; the
      # encoder's declared type stands in.
      def narrowed_side(type, enc)
        output = enc.output_type
        return nil if type == output
        return nil unless Plumb::Subtyping.value_preserving?(type)
        return nil unless Plumb::Subtyping.subtype?(type, output) && !Plumb::Subtyping.subtype?(output, type)

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
        v.equal?(element) ? type : type[v]
      end

      def visit_tuple(type, path)
        members = type.children.each_with_index.map { |m, i| visit(m, path + ["[#{i}]"]) }
        members.zip(type.children).all? { |v, m| v.equal?(m) } ? type : type.of(*members)
      end

      # Keys are left untouched — key normalization (eg. string keys from the
      # input) is a separate concern (see Types::SymbolizedHash / #symbolized).
      def visit_hash_map(type, path)
        key_type, value_type = type.children
        v = visit(value_type, path + ['{}'])
        # type.class (not HashMap) to preserve FilteredHashMap's leniency.
        v.equal?(value_type) ? type : type.class.new(key_type, v)
      end

      # A tagged union of Hash variants discriminated by a key: rewrite each
      # variant schema (all HashClasses); the tag key's literal value is a
      # native pass-through, so the discriminator survives.
      def visit_tagged_hash(type, path)
        variants = type.children.map { |c| visit(c, path) }
        return type if variants.zip(type.children).all? { |v, c| v.equal?(c) }

        TaggedHash.new(type.hash_type, type.key, variants)
      end

      def visit_or(type, path)
        left, right = type.children
        l = visit(left, path)
        r = visit(right, path)
        l.equal?(left) && r.equal?(right) ? type : Or.new(l, r)
      end

      # An And chain is a data-bearing type refined by pure filters (a #where's
      # AttributeValueMatch, a #check Constraint, ...). Rewrite the data type(s).
      # On DECODE the codec replaces the schema, so the refinements are the only
      # validation of the decoded value — keep them AFTER the input ->
      # output conversion. On ENCODE the schema has already validated the
      # value (the suffix runs inside `And(schema, suffix)`), so the refinements
      # are redundant and would run on the produced input value — drop them.
      def visit_and(type, path)
        steps = flatten_and(type)
        refinements, data = steps.partition { |s| pure_refinement?(s) }
        rewritten = data.map { |d| visit(d, path) }
        return type if rewritten.each_with_index.all? { |r, i| r.equal?(data[i]) }

        ordered = @direction == :decode ? rewritten + refinements : rewritten
        ordered.reduce { |l, r| And.new(l, r) }
      end

      def flatten_and(type)
        type.children.flat_map { |c| c.is_a?(And) ? flatten_and(c) : [c] }
      end

      # A pure refinement carries no encodable type — it filters the adjacent
      # type's values. A bare-matcher Constraint (opaque input, refining a
      # sibling) qualifies, but a base-type Constraint — `Types::Date` IS
      # `Constraint(::Date)` — is data an encoder must see (eg. in
      # `Types::Date.where(year: ...)` == `And(Constraint(::Date), AVM)`).
      def pure_refinement?(child)
        case child
        when AttributeValueMatch, ValueClass, Not then true
        when Constraint then child.input_type.is_a?(AnyClass)
        else false
        end
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

      # Visit a transparent wrapper's inner type; keep the wrapper when
      # nothing changed, else re-wrap via the block.
      def rebuild(original, inner, path)
        v = visit(inner, path)
        v.equal?(inner) ? original : yield(v)
      end
    end

    # ------------------------------------------------------------------
    # Shared, format-neutral encoders — string representations standardized
    # by ISO 8601 (dates, times) and RFC 3986 (URIs) — registered by both
    # built-in codecs, and usable per-field in any schema. Their input types
    # carry `format:` metadata, so generated JSON Schemas describe the fields
    # as eg. `{type: "string", format: "date"}`.
    # ------------------------------------------------------------------

    TIME_EXPR = /\A\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?\z/
    # Scheme-prefixed URI strings, per RFC 3986 — URI.parse alone is too
    # permissive (a blank string is a valid URI).
    URI_EXPR = /\A[a-z][a-z0-9+\-.]*:/i
    # Decimal or scientific notation — Float#to_s emits scientific for very
    # small/large magnitudes ("1.0e-05"), so the input type must accept what
    # encode produces or a valid Float fails its own round-trip.
    FLOAT_EXPR = /\A-?\d+(\.\d+)?([eE][+-]?\d+)?\z/

    # Date <=> ISO 8601 date string ("2024-01-30").
    class DateEncoder < Encoder[Types::String[/\A\d{4}-\d{2}-\d{2}\z/].metadata(format: 'date') => Types::Date]
      def encode(date) = date.iso8601
      def decode(str) = ::Date.parse(str)
    end

    # Time <=> ISO 8601 date-time string ("2024-08-30T20:15:23Z").
    class TimeEncoder < Encoder[Types::String[TIME_EXPR].metadata(format: 'date-time') => Types::Time]
      def encode(time) = time.iso8601
      def decode(str) = ::Time.parse(str)
    end

    # Symbol <=> String. Ruby data structures use Symbols for enum-ish
    # values (`status: :active`); the encoded form carries them as strings.
    # A narrowed field (`Types::Symbol[:draft, :published]`) keeps its check.
    class SymbolEncoder < Encoder[Types::String => Types::Symbol]
      def encode(sym) = sym.to_s
      def decode(str) = str.to_sym
    end

    # BigDecimal <=> canonical decimal string ("1.5"). A string, not a
    # number: decimals exist to avoid float precision loss, and JSON numbers
    # are floats. In Codec::JSON this also keeps Decimal fields from silently
    # noop-passing via the Numeric noop (a BigDecimal is not JSON-native).
    class DecimalEncoder < Encoder[Types::String[FLOAT_EXPR] => Types::Decimal]
      def encode(dec) = dec.to_s('F')
      def decode(str) = BigDecimal(str)
    end

    # URI <=> scheme-prefixed URI string. The narrower HTTP/File variants win
    # most-specific matching for fields typed as such; the produced value is
    # validated against the declared URI class.
    class URIEncoder < Encoder[Types::String[URI_EXPR].metadata(format: 'uri') => Types::URI::Generic]
      def encode(uri) = uri.to_s
      def decode(str) = ::URI.parse(str)
    end

    # Re-parameterized subclasses: same input type and methods, narrower
    # output — the produced URI is validated against the declared class.
    HTTPURIEncoder = URIEncoder[URIEncoder.input_type => Types::URI::HTTP]
    FileURIEncoder = URIEncoder[URIEncoder.input_type => Types::URI::File]

    # Range <=> a JSON object `{ from:, to:, exclusive: }`. Generic over the
    # range's member type: it matches ANY `Range[member]` (its output type is
    # the Range top), and #input_type_for builds the input from the matched
    # member — so a `Range[Date]` serializes its endpoints as ISO strings, a
    # `Range[Integer]` as JSON numbers, etc., because the codec rewrites those
    # member-typed `from`/`to` fields through itself. `from`/`to` are nullable
    # for beginless/endless ranges; `exclusive` records whether the end is
    # excluded (`1...5` vs `1..5`).
    class RangeEncoder < Encoder[
      Types::Hash[
        from: Types::Any.nullable,
        to: Types::Any.nullable,
        exclusive: Types::Boolean
      ] => Types::Range
    ]
      # Specialize the input to the matched range's member type. A non-Range
      # match (should not happen — only RangeClass is a subtype of the Range
      # top) falls back to the generic declared input.
      def self.input_type_for(matched)
        return input_type unless matched.is_a?(Plumb::RangeClass)

        member = matched.children.first
        Types::Hash[
          from: member.nullable,
          to: member.nullable,
          exclusive: Types::Boolean
        ]
      end

      def encode(range)
        { from: range.begin, to: range.end, exclusive: range.exclude_end? }
      end

      def decode(hash)
        ::Range.new(hash[:from], hash[:to], hash[:exclusive])
      end
    end

    # A base codec for JSON-like targets: the scalars native to JSON pass
    # through (structured containers are handled structurally by the rewrite;
    # the bare Hash/Array tops cover untyped ones), and Dates/Times/URIs map
    # to their standard string forms. Subclass it and register encoders:
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

      encoder DateEncoder, TimeEncoder, SymbolEncoder, DecimalEncoder
      encoder URIEncoder, HTTPURIEncoder, FileURIEncoder
      encoder RangeEncoder
    end

    # A base codec for string-based formats — HTML forms, query strings, CSV
    # cells — where EVERY value arrives as a string. Unlike Codec::JSON there
    # are almost no native scalars: strings pass through, untyped containers
    # recurse structurally (Rack-style nested params), and everything else
    # maps through an encoder whose input type is a strictly-patterned string.
    #
    #   Config = Types::Hash[port: Types::Integer, active: Types::Boolean, on: Types::Date]
    #   decoder, encoder = Plumb::Codec::Forms.for(Config)
    #   decoder.parse({ port: '80', active: '1', on: '2024-01-30' })
    #   # => { port: 80, active: true, on: Date(2024-01-30) }
    class Forms < self
      INTEGER_EXPR = /\A-?\d+\z/

      class IntegerEncoder < Encoder[Types::String[INTEGER_EXPR] => Integer]
        def encode(int) = int.to_s
        def decode(str) = str.to_i
      end

      class FloatEncoder < Encoder[Types::String[FLOAT_EXPR] => Float]
        def encode(float) = float.to_s
        def decode(str) = str.to_f
      end

      # For fields typed as the Numeric union. A more specific field (Integer,
      # Float, Decimal) picks its own encoder via most-specific matching.
      class NumericEncoder < Encoder[Types::String[FLOAT_EXPR] => Numeric]
        def encode(num) = num.is_a?(BigDecimal) ? num.to_s('F') : num.to_s
        # A fractional or scientific string is a Float; a plain integer literal
        # is an Integer ("1e20".to_i would wrongly be 1).
        def decode(str) = str.match?(/[.eE]/) ? str.to_f : str.to_i
      end

      # Booleans are two encoders: a field typed Types::Boolean is the
      # `True | False` union underneath, and each branch matches its own.
      class TrueEncoder < Encoder[(Types::String[/\Atrue\z/i] | '1') => Types::True]
        def encode(_bool) = 'true'
        def decode(_str) = true
      end

      class FalseEncoder < Encoder[(Types::String[/\Afalse\z/i] | '0') => Types::False]
        def encode(_bool) = 'false'
        def decode(_str) = false
      end

      # An empty or absent form field is nil — so `Types::Date | Types::Nil`
      # decodes '' AND a literal nil (valueless params, eg. Rack's
      # `parse_nested_query('x')`) to nil, and '2024-01-30' to a Date. The Nil
      # in the input is left as a literal acceptance during input rewriting (it
      # is noop-covered), not recursively re-encoded.
      class NilEncoder < Encoder[(Types::String[''] | Types::Nil) => Types::Nil]
        def encode(_nil) = ''
        def decode(_value) = nil
      end

      noop Types::String, Types::Nil, Types::Hash, Types::Array

      encoder IntegerEncoder, FloatEncoder, NumericEncoder
      encoder TrueEncoder, FalseEncoder, NilEncoder
      # Format-neutral string encoders, shared with Codec::JSON.
      encoder DateEncoder, TimeEncoder, SymbolEncoder, DecimalEncoder
      encoder URIEncoder, HTTPURIEncoder, FileURIEncoder
    end
  end
end

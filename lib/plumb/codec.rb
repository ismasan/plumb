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
  # encoder step (a plain Function, see Encoder.step); noop-matched types
  # pass through unchanged; anything else
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

      left = Composable.wrap(left)
      # A plain-include struct wraps as an opaque Step (output Any), so its
      # rewrite target is the struct node itself, not its resolved output.
      target = Rewriter.struct_class(left) ? left : Plumb::Subtyping.resolved_output(left)
      Rewriter.new(self, :encode).call(target)
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

      side = direction == :decode ? Plumb::Subtyping.accepted_type(type) : Plumb::Subtyping.resolved_output(type)
      Plumb::Subtyping.subtype?(side, @noop_union)
    end

    # Is this concrete VALUE covered by the noop types? Used for Static nodes,
    # whose fixed value can be validated directly — subtyping over the node
    # can't relate an atomic Static to a container noop (`Static[[]]` vs
    # `Types::Array`), but the value itself can just be checked.
    def noop_value?(value)
      return false unless @noop_union

      @noop_union.resolve(value).valid?
    end

    def at_path(path) = path.empty? ? 'the root type' : "field `#{path.join('.')}`"

    private def _inspect
      "#{self.class == Codec ? 'Plumb::Codec' : self.class.name}[#{encoders.reject(&:noop?).map(&:inspect).join(', ')}]"
    end

    # The deep rewrite walker. Top-down, per node:
    #
    #   1. Static values, Or/And chains and transparent wrappers recurse into
    #      their parts first — they can carry generator machinery (a
    #      `.default`'s `Undefined >> Static` guard) that a wholesale
    #      replacement would drop (see #visit);
    #   2. a real encoder match replaces the node whole (its wire type is
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
      # The struct class behind `type`, or nil. Structs appear in two shapes:
      # a Composable-extended class (Types::Data subclasses — the class IS the
      # node), or an opaque Step wrapping a plain `include Plumb::Attributes`
      # class (what Composable.wrap makes of one — same shape
      # Attributes#build_nested detects).
      def self.struct_class(type)
        return type if type.is_a?(::Class) && type <= Plumb::Attributes
        return nil unless type.is_a?(Plumb::Step)

        callable = type.children.first
        callable.is_a?(::Class) && callable <= Plumb::Attributes ? callable : nil
      end

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
        # Before encoder matching: a Static's fixed value would otherwise
        # match an encoder atomically (`Static[a_date]` is a subtype of Date)
        # and get replaced by a step that expects wire input, losing the
        # static behaviour (eg. the default value in a `.default(...)`).
        return visit_static(type, path) if type.is_a?(StaticClass)

        # Or/And chains and transparent wrappers also recurse BEFORE encoder
        # matching: they can carry generator guards (`(Undefined >> Static) |
        # T`, the #default shape) that are subtype-wise invisible — the whole
        # composition IS a subtype of T — but would be dropped by a wholesale
        # replacement. Recursing rewrites the data-bearing parts and keeps the
        # machinery; an encoder with a union internal type still matches at
        # branch level.
        #
        # One exception: a value-preserving composite that is fully
        # noop-covered converts nothing and needs no rewriting — pass it
        # through whole. Factored refinement unions rely on this: a union of
        # noop-type refinements (eg. `String[/\Atrue\z/i] | String['1']`)
        # factors into a shape whose bare-matcher branches report opaque
        # accepted types and would defeat the leaf-level noop check.
        case type
        when Or, And, Metadata, Policy, Composable::Node
          return type if Plumb::Subtyping.value_preserving?(type) && @codec.noop?(type, @direction)
        end

        case type
        when Or then return visit_or(type, path)
        when And then return visit_and(type, path)
        when Metadata then return rebuild(type, visit(type.type, path)) { |t| Metadata.new(t, type.metadata) }
        when Policy then return rebuild(type, visit(type.children.first, path)) { |t| Policy.new(type.policy_name, type.arg, t) }
        when Composable::Node then return rebuild(type, visit(type.type, path)) { |t| t.as_node(type.node_name, type.args) }
        end

        if (enc = @codec.encoder_for(type, path))
          return replace(type, enc, path)
        end

        case type
        when HashClass then visit_hash(type, path)
        when ArrayClass, StreamClass then visit_array(type, path)
        when TupleClass then visit_tuple(type, path)
        when HashMap then visit_hash_map(type, path)
        else
          if (struct = self.class.struct_class(type))
            visit_struct(type, struct, path)
          else
            noop_or_fail(type, path)
          end
        end
      end

      # A struct (Types::Data / Plumb::Attributes) is a Hash schema plus a
      # constructor. Decoding, the rewritten schema turns wire fields into
      # internal values and the class itself builds the instance (Transform's
      # output stage CALLS it). Encoding, the class validates/constructs the
      # instance, `#attributes` exposes the internal values (shallow — nested
      # structs stay instances and are handled by their own rewritten nodes,
      # unlike the deep #to_h), and the encode-rewritten schema turns them
      # into wire values. Either way a single Transform node, so accepted/
      # produced types and the JSON Schema stay honest.
      def visit_struct(original, struct, path)
        schema = visit(struct._schema, path)
        if @direction == :decode
          # All fields wire-native already: the struct validates and
          # constructs by itself.
          return original if schema.equal?(struct._schema)

          Transform.new(schema, struct, Plumb::NOOP)
        else
          Transform.new(struct, schema, ->(result) { result.valid!(result.value.attributes) })
        end
      end

      # A Static ignores its input and emits a fixed value (eg. the default in
      # a `.default(...)` composition). Decoding, that value is part of the
      # internal structure the schema declares — keep it as-is.
      #
      # Encoding is different: the suffix runs on values the schema has
      # ALREADY produced (the Static ran when the schema did), and
      # resolved_output collapses the `Undefined >> Static` guard of a
      # #default, leaving the Static as an always-matching first Or branch —
      # re-running it would clobber the actual value with the default. So on
      # encode a Static becomes a CHECKED value: match the static value
      # (against the VALUE, not the node — subtyping can't relate an atomic
      # Static to a container noop), then emit its wire form — the value
      # itself when noop-covered, or its encoding, computed once here at
      # composition time (the value is fixed, so its encoding is too).
      def visit_static(type, path)
        return type if @direction == :decode

        value = type.children.first
        return ValueClass.new(value) if @codec.noop_value?(value)

        if (enc = @codec.encoder_for(type, path))
          encoded = replace(type, enc, path).parse(value)
          encoded = encoded.freeze unless encoded.frozen?
          And.new(ValueClass.new(value), StaticClass.new(encoded))
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
          enc.step(:decode,
                   input_type: (rewritten_wire unless rewritten_wire.equal?(wire)),
                   output_type: narrowed)
        else
          enc.step(:encode,
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

      # An And chain (refinement/sequence): rewrite the data-bearing children;
      # pure refinements (checks, #where clauses, value matchers) filter the
      # adjacent type's values and pass through.
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

    # A base codec for stringly wire formats — HTML forms, query strings, CSV
    # cells — where EVERY value arrives as a string. Unlike Codec::JSON there
    # are almost no native scalars: strings pass through, untyped containers
    # recurse structurally (Rack-style nested params), and everything else
    # maps through an encoder whose wire type is a strictly-patterned string.
    #
    #   Config = Types::Hash[port: Types::Integer, active: Types::Boolean, on: Types::Date]
    #   decoder, encoder = Plumb::Codec::Forms.for(Config)
    #   decoder.parse({ port: '80', active: '1', on: '2024-01-30' })
    #   # => { port: 80, active: true, on: Date(2024-01-30) }
    class Forms < self
      INTEGER_EXPR = /\A-?\d+\z/
      FLOAT_EXPR = /\A-?\d+(\.\d+)?\z/
      TIME_EXPR = /\A\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?\z/

      class IntegerEncoder < Encoder[Types::String[INTEGER_EXPR] => Types::Integer]
        def encode(int) = int.to_s
        def decode(str) = str.to_i
      end

      class FloatEncoder < Encoder[Types::String[FLOAT_EXPR] => Types::Float]
        def encode(float) = float.to_s
        def decode(str) = str.to_f
      end

      class DecimalEncoder < Encoder[Types::String[FLOAT_EXPR] => Types::Decimal]
        def encode(dec) = dec.to_s('F')
        def decode(str) = BigDecimal(str)
      end

      # For fields typed as the Numeric union. A more specific field (Integer,
      # Float, Decimal) picks its own encoder via most-specific matching.
      class NumericEncoder < Encoder[Types::String[FLOAT_EXPR] => Types::Numeric]
        def encode(num) = num.is_a?(BigDecimal) ? num.to_s('F') : num.to_s
        def decode(str) = str.include?('.') ? str.to_f : str.to_i
      end

      # Booleans are two encoders: a field typed Types::Boolean is the
      # `True | False` union underneath, and each branch matches its own.
      class TrueEncoder < Encoder[(Types::String[/\Atrue\z/i] | Types::String['1']) => Types::True]
        def encode(_bool) = 'true'
        def decode(_str) = true
      end

      class FalseEncoder < Encoder[(Types::String[/\Afalse\z/i] | Types::String['0']) => Types::False]
        def encode(_bool) = 'false'
        def decode(_str) = false
      end

      # An empty form field is nil — so `Types::Date | Types::Nil` decodes ''
      # to nil and '2024-01-30' to a Date.
      class NilEncoder < Encoder[Types::String[''] => Types::Nil]
        def encode(_nil) = ''
        def decode(_str) = nil
      end

      class TimeEncoder < Encoder[Types::String[TIME_EXPR].metadata(format: 'date-time') => Types::Time]
        def encode(time) = time.iso8601
        def decode(str) = ::Time.parse(str)
      end

      # Scheme-prefixed URI strings, per RFC 3986 — URI.parse alone is too
      # permissive (a blank string is a valid URI). The narrower HTTP/File
      # variants win most-specific matching for fields typed as such; the
      # produced value is validated against the declared URI class.
      URI_EXPR = /\A[a-z][a-z0-9+\-.]*:/i

      class URIEncoder < Encoder[Types::String[URI_EXPR].metadata(format: 'uri') => Types::URI::Generic]
        def encode(uri) = uri.to_s
        def decode(str) = ::URI.parse(str)
      end

      class HTTPURIEncoder < Encoder[Types::String[URI_EXPR].metadata(format: 'uri') => Types::URI::HTTP]
        def encode(uri) = uri.to_s
        def decode(str) = ::URI.parse(str)
      end

      class FileURIEncoder < Encoder[Types::String[URI_EXPR].metadata(format: 'uri') => Types::URI::File]
        def encode(uri) = uri.to_s
        def decode(str) = ::URI.parse(str)
      end

      noop Types::String, Types::Hash, Types::Array

      encoder IntegerEncoder, FloatEncoder, DecimalEncoder, NumericEncoder
      encoder TrueEncoder, FalseEncoder, NilEncoder
      encoder JSONDateEncoder # ISO 8601 date strings — shared with Codec::JSON
      encoder TimeEncoder
      encoder URIEncoder, HTTPURIEncoder, FileURIEncoder
    end
  end
end

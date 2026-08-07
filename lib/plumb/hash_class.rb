# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/key'
require 'plumb/static_class'
require 'plumb/function'
require 'plumb/hash_map'
require 'plumb/tagged_hash'

module Plumb
  class HashClass
    include Composable

    NOT_A_HASH = { _: 'must be a Hash' }.freeze

    attr_reader :_schema

    # @param schema [Hash] field definitions keyed by literal or matcher keys
    # @param closed [Boolean] whether values contain only declared keys
    def initialize(schema: BLANK_HASH, closed: false)
      @closed = closed
      @_schema = wrap_keys_and_values(schema)
      # Partition once (the instance is frozen): literal keys use exact lookup in
      # #call; matcher keys (typed keys and the `_` catch-all) are matched against
      # leftover input keys. `_schema` stays the source of truth for ==/subtyping.
      @literal_fields = @_schema.select { |k, _| k.literal? }
      @matcher_fields = @_schema.reject { |k, _| k.literal? }
      # The `_` catch-all's value type, if present (there is at most one).
      @catch_all_type = @_schema.find { |k, _| k.catch_all? }&.last
      freeze
    end

    # The `_` catch-all value type (what every otherwise-unmatched key must be),
    # or nil when the schema is closed. See #call / #&.
    attr_reader :catch_all_type

    # Input schemas are open because #call ignores extra keys; produced literal-key
    # records are closed because #call emits only declared keys.
    # @return [Boolean] whether values contain only declared keys
    def closed? = @closed

    # Returns the closed form emitted by a literal-key schema.
    # Matcher-key and empty schemas remain open because they can pass unknown keys.
    # @return [HashClass]
    def closed
      return self if @closed || _schema.empty? || !@matcher_fields.empty?

      self.class.new(schema: _schema, closed: true)
    end

    # The literal (Symbol/String) entries of the schema.
    attr_reader :literal_fields

    # The matcher (typed/catch-all) entries of the schema.
    attr_reader :matcher_fields

    # Only a single `_` catch-all and no named/typed keys — the "open any-key map"
    # shape (`Hash[_: V]`). Used by HashMap subtyping.
    def only_catch_all? = @literal_fields.empty? && @matcher_fields.size == 1 && !@catch_all_type.nil?

    # A Hash type with a specific schema.
    # Option 1: a Hash representing schema
    #
    #   Types::Hash[name: Types::String.present, age?: Types::Integer]
    #
    # Option 2: a Map with pre-defined types for all keys and values
    #
    #   Types::Hash[Types::String, Types::Integer]
    def schema(*args)
      case args
      in [::Hash => hash]
        self.class.new(schema: _schema.merge(wrap_keys_and_values(hash)))
      in [key_type, value_type]
        HashMap.new(Composable.wrap(key_type), Composable.wrap(value_type))
      else
        raise ::ArgumentError, "unexpected value to Types::Hash#schema #{args.inspect}"
      end
    end

    alias [] schema

    # Hash#merge keeps the left-side key in the new hash
    # if they match via #hash and #eql?
    # we need to keep the right-side key, because even if the key name is the same,
    # it's optional flag might have changed
    def +(other)
      other_schema = case other
                     when HashClass then other._schema
                     when ::Hash then other
                     else
                       raise ArgumentError, "expected a HashClass or Hash, got #{other.class}"
                     end

      self.class.new(schema: merge_rightmost_keys(_schema, other_schema))
    end

    # Intersects shared fields and any fields admitted by the other schema's
    # catch-all. The empty schema is the Hash top; disjoint non-empty schemas
    # produce Never. Non-Hash operands use the generic intersection.
    # @param other [Object]
    # @return [HashClass, Composable]
    def &(other)
      # Route through the intersection hook (not bare Composable.wrap) so a
      # context-resolving operand — eg. an Encoder class — orients against this
      # Hash instead of defaulting to its decode direction (which would make
      # `Hash & EncoderClass` collapse to Never). Mirrors Composable#&.
      other = Composable.resolve_operand(other, op: :&, left: self)
      return super unless other.is_a?(HashClass)

      # The any-Hash top is the identity of intersection: Hash[] & X == X.
      return other if _schema.empty?
      return self if other._schema.empty?

      my_catch = catch_all_type
      their_catch = other.catch_all_type
      result = {}

      non_catch_all_schema.each do |my_key, my_field|
        if (other_key = other.stored_key(my_key))
          # shared key: intersect fields; optionality from `other` (right wins).
          result[other_key] = my_field & other._schema[other_key]
        elsif their_catch # kept only if the other side's catch-all admits it
          result[my_key] = my_field & their_catch
        end
      end

      other.non_catch_all_schema.each do |their_key, their_field|
        next if stored_key(their_key) # already handled as a shared key

        result[their_key] = their_field & my_catch if my_catch
      end

      # Preserve every non-Any constraint on unmatched keys. A closed side may drop
      # extras, but an open side still validates them; dropping its lone catch-all
      # would admit values that the open side rejects.
      tail = my_catch && their_catch ? my_catch & their_catch : (my_catch || their_catch)
      result[Key.new(Types::Any)] = tail if tail && !tail.is_a?(AnyClass)

      return Types::Never if result.empty? # two closed schemas that share nothing

      self.class.new(schema: result)
    end

    def tagged_by(key, *types)
      TaggedHash.new(self, key, types)
    end

    def at_key(a_key)
      _schema[Key.wrap(a_key)]
    end

    def to_h = _schema

    # A lenient version of this Hash: it accepts any Hash and emits one with only
    # the valid schema fields, dropping invalid/missing/extra ones. As a type it
    # declares `#input_type` as this schema and `#output_type` as this schema
    # with every key relaxed to optional (any field may be dropped), so it
    # participates in subtyping (see FilteredHash).
    def filtered
      op = lambda do |result|
        return result.invalid!(errors: 'must be a Hash') unless result.value.is_a?(::Hash)
        return result unless _schema.any?

        input = result.value
        # Reuse the incoming cursor as the per-field scratch (see #call): `input`
        # is captured above and `result` is only flipped at the end, so fields
        # reset it in place with no scratch allocation.
        output = {}
        @literal_fields.each do |key, field|
          key_s = key.to_key
          if input.key?(key_s)
            r = field.call(result.reset(input[key_s]))
            output[key_s] = r.value if r.valid?
          elsif !key.optional?
            r = field.call(result.reset(Undefined))
            output[key_s] = r.value if r.valid?
          end
        end
        unless @matcher_fields.empty?
          input.each do |k, v|
            next if output.key?(k)

            match = @matcher_fields.find { |mk, _| mk.match?(k) }
            next unless match

            r = match[1].call(result.reset(v))
            output[k] = r.value if r.valid?
          end
        end
        result.valid!(output)
      end
      # `op` is built fresh per call, so name what the step IS as its identity —
      # otherwise every `.filtered` node is unequal to every other, and so is any
      # composite containing one. @see Function#==
      FilteredHash.new(self, relaxed_to_optional, op, identity: [:filtered_hash, self])
    end

    # A version of this Hash that first symbolizes string keys (via
    # Types::SymbolizedHash) and then validates against this schema. Use it
    # instead of `Types::SymbolizedHash >> self`, which the strict composition
    # check rejects — a Symbol-keyed map doesn't guarantee this schema's keys, so
    # this declares the step as a #transform (conversion) instead.
    def symbolized
      Types::SymbolizedHash / self
    end

    def call(result)
      return result.invalid!(errors: NOT_A_HASH) unless result.value.is_a?(::Hash)
      return result unless _schema.any?

      input = result.value
      errors = nil # Do not allocate errors unless needed
      output = {}

      # Pass 1 — literal keys by exact lookup (the fast path). Reuse the incoming
      # cursor as the per-field scratch: `input` is captured above and `result` is
      # not read again until the final flip below, so each field can reset it in
      # place — a Hash validates with zero Result allocations of its own.
      # `output`/`errors` hold the fields' values/errors by reference (read out
      # immediately per field), and #reset only reassigns the cursor's slots, so
      # previously stored entries are never mutated. This mirrors ArrayClass's
      # element-cursor reuse; a field whose value is lazily consumed later (a
      # Stream) snapshots its own source, so it stays correct.
      @literal_fields.each do |key, field|
        key_s = key.to_key
        if input.key?(key_s)
          r = field.call(result.reset(input[key_s]))
          output[key_s] = r.value
          unless r.valid?
            errors ||= {}
            errors[key_s] = r.errors
          end
        elsif !key.optional?
          r = field.call(result.reset(Undefined))
          output[key_s] = r.value unless r.value == Undefined
          unless r.valid?
            errors ||= {}
            errors[key_s] = r.errors
          end
        end
      end

      # Pass 2 — leftover input keys against matcher keys (typed keys + the `_`
      # catch-all), first match wins. Keys matching nothing are dropped (the
      # non-inclusive default). Matcher keys never impose a required key.
      unless @matcher_fields.empty?
        input.each do |k, v|
          next if output.key?(k)

          match = @matcher_fields.find { |mk, _| mk.match?(k) }
          next unless match

          r = match[1].call(result.reset(v))
          output[k] = r.value
          unless r.valid?
            errors ||= {}
            errors[k] = r.errors
          end
        end
      end

      errors ? result.invalid!(output, errors:) : result.valid!(output)
    end

    def ==(other)
      return false unless other.is_a?(self.class) && _schema.size == other._schema.size

      # `Key#eql?`/`#hash` compare names only, so a raw `_schema == _schema`
      # would treat `name?:` and `name:` as equal. Two Hash types that differ in
      # a key's optionality are different types, so compare that too.
      _schema.all? do |key, value|
        other_key, other_value = other._schema.find { |k, _| k.eql?(key) }
        other_key && key.optional? == other_key.optional? && value == other_value
      end
    end

    # Width + depth subtyping over Hash schemas. `self <= other` when, for every
    # key `other` requires, `self` provides it as a *required* key whose type is
    # a subtype (depth) — `self` may add keys (width), and a key `other` makes
    # optional need not be present. A key `other` requires but `self` only holds
    # optionally is NOT enough: `self` could omit it. An empty schema
    # (`Types::Hash`) is the "any Hash" top within the Hash family.
    def subtype_of?(other)
      return true if self == other
      return hashmap_subtype?(other) if other.is_a?(HashMap)
      return false unless other.is_a?(HashClass)

      # The unconstrained Hash is the top of this family, never a narrower subtype.
      return false if _schema.empty?
      return true if other._schema.empty?

      named_keys_ok?(other) && carried_keys_ok?(other) && tail_ok?(other)
    end

    # As a consumer, this Hash accepts each field relaxed to what *that* field
    # accepts — so a converting field (eg. `price: Integer.build(Money)`) accepts
    # an Integer, not the Money it produces. Only field types change; keys and
    # optionality are preserved, so ordinary record subtyping is unchanged. This
    # is what lets `Hash[price: Integer] >> Hash[price: Integer.build(Money)]`
    # type-check (the front-end/back-end coercion pattern).
    def accepted_type
      relaxed = _schema.each_with_object({}) do |(key, field), h|
        h[key] = Plumb::Subtyping.accepted_type(field)
      end
      self.class.new(schema: relaxed)
    end

    # The value you GET after running the schema: each field resolved to what it
    # produces, so `Hash[age: String >> Integer].output_type` is `Hash[age:
    # Integer]` (mirror of #accepted_type on the input side). Idempotent — when
    # no field converts, every field's resolved output IS the field, so this
    # returns `self` and Subtyping.resolved_output reaches its fixpoint in one
    # step. Only field types change; keys and optionality are preserved.
    def output_type
      resolved = _schema.each_with_object({}) do |(key, field), h|
        h[key] = Plumb::Subtyping.resolved_output(field)
      end
      resolved.any? { |k, f| !f.equal?(_schema[k]) } ? self.class.new(schema: resolved) : self
    end

    protected

    # The schema entries excluding the `_` catch-all (the named + typed keys).
    def non_catch_all_schema = @_schema.reject { |k, _| k.catch_all? }

    # The Key instance stored in this schema that is eql? to `key` (so callers can
    # read the owning side's optionality), or nil.
    def stored_key(key) = @_schema.each_key.find { |k| k.eql?(key) }

    private

    # Checks required keys and the types of optional keys that self may carry.
    def named_keys_ok?(other)
      other.literal_fields.all? do |other_key, other_field|
        mine_key, mine_field = _schema.find { |k, _| k.eql?(other_key) }
        if mine_field
          Plumb::Subtyping.subtype?(mine_field, other_field) &&
            (other_key.optional? || !mine_key.optional?)
        else
          # "Optional" does not mean impossible: matcher keys or a catch-all may
          # still carry this name. Closed records omit it; open records must
          # constrain any value they can carry there.
          other_key.optional? && (closed? || promises?(guarantee_for(other_key.to_key), other_field))
        end
      end
    end

    # Returns the first matcher field that claims an undeclared key.
    def guarantee_for(key_name)
      @matcher_fields.find { |mk, _| mk.match?(key_name) }&.last
    end

    # Checks that self's open tail satisfies every matcher field in other.
    def tail_ok?(other)
      return true if closed? # no tail for `other`'s matcher keys to constrain

      other.matcher_fields.all? { |_k, f| promises?(catch_all_type, f) }
    end

    # Tests whether an optional guarantee satisfies a requested field type.
    def promises?(guaranteed, wanted)
      return true if wanted.is_a?(AnyClass)

      !guaranteed.nil? && Plumb::Subtyping.subtype?(guaranteed, wanted)
    end

    # Checks every carried key against overlapping matcher fields in other.
    def carried_keys_ok?(other)
      _schema.all? do |mine_key, mine_field|
        theirs = other._schema.find { |ok, _| ok.eql?(mine_key) }
        if theirs
          # named_keys_ok? already checked literal fields.
          mine_key.literal? || Plumb::Subtyping.subtype?(mine_field, theirs.last)
        else
          other.matcher_fields.all? do |other_key, other_field|
            !keys_may_overlap?(mine_key, other_key) ||
              Plumb::Subtyping.subtype?(mine_field, other_field)
          end
        end
      end
    end

    # Tests literal overlap exactly; assumes two arbitrary matchers may overlap.
    def keys_may_overlap?(mine, theirs)
      return mine.eql?(theirs) if mine.literal? && theirs.literal?
      return theirs.match?(mine.to_key) if mine.literal?
      return mine.match?(theirs.to_key) if theirs.literal?

      true
    end

    def hashmap_subtype?(other)
      return false if _schema.empty?
      # Open records need a catch-all to constrain every map entry.
      return false unless closed? || catch_all_type

      key_type, value_type = other.children
      _schema.all? do |key, field|
        key_matcher = key.literal? ? Composable.wrap(key.to_key) : key.matcher
        Plumb::Subtyping.subtype?(key_matcher, key_type) &&
          Plumb::Subtyping.subtype?(field, value_type)
      end
    end

    # This schema with every key relaxed to optional (same value types). Used as
    # the output type of #filtered, which may drop any field. Matcher keys (typed/
    # catch-all) are already optional, so they pass through unchanged.
    def relaxed_to_optional
      relaxed = _schema.each_with_object({}) do |(key, type), h|
        new_key = key.literal? ? Key.new(key.to_key, optional: true) : key
        h[new_key] = type
      end
      self.class.new(schema: relaxed)
    end

    def _inspect
      %(Hash[#{_schema.map { |(k, v)| [k.inspect, v.inspect].join(': ') }.join(', ')}])
    end

    def wrap_keys_and_values(hash)
      hash.each.with_object({}) do |(k, v), ret|
        # `_:` is sugar for a catch-all key over the Any top. Only intercept a raw
        # `:_` symbol (the schema-literal syntax); an already-wrapped Key (from #+,
        # #&, relaxed/accepted rebuilds, or a Data attribute) passes through as-is.
        key = k == :_ ? Key.new(Types::Any) : Key.wrap(k)
        ret[key] = Composable.wrap(v)
      end
    end

    def merge_rightmost_keys(hash1, hash2)
      hash2.each.with_object(hash1.clone) do |(k, v), memo|
        # assigning a key that already exist with #hash and #eql
        # leaves the original key instance in place.
        # but we want the hash2 key there, because its optionality could have changed.
        memo.delete(k) if memo.key?(k)
        memo[k] = v
      end
    end
  end

  # The typed node returned by HashClass#filtered. It is a Function — so #>>
  # treats it as a conversion (subtype by its output, accepted by its input) and
  # it bypasses the strict composition check — declaring `input_type` as the
  # filtered schema and `output_type` as that schema with all keys optional. But
  # unlike a plain Function it does NOT strict-validate its input: #call runs
  # the lenient filter, which accepts any Hash and drops invalid/missing/extra
  # fields.
  class FilteredHash < Function
    # Naming derives #node_name when Composable is *included* (on Function), so
    # the subclass would otherwise inherit :function.
    def node_name = :filtered_hash

    # A filtered Hash is lenient: it accepts ANY hash and drops invalid/missing/
    # extra fields (it never rejects a Hash), so as a #>> consumer it accepts any
    # hash-like value. (Its #input_type still declares the schema it relaxes.)
    def accepted_type = Types::EachPair

    # Re-derived, NOT rebuilt around the old #fn: the filter closes over the schema it
    # was built from, so Function#with_children returns a node that inspects as the
    # new schema and still filters by the old one.
    def with_children(children) = children.first.filtered

    # Neither boundary check runs — the per-field validation in HashClass#filtered
    # subsumes both. Overriding #call is also what excludes this node from fusion,
    # with nothing further to declare. @see Function#fusable_step?
    def call(result) = fn.call(result)

    private def _inspect = "#{input_type.inspect}.filtered"
  end
end

# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/key'
require 'plumb/static_class'
require 'plumb/transform'
require 'plumb/hash_map'
require 'plumb/tagged_hash'

module Plumb
  class HashClass
    include Composable

    NOT_A_HASH = { _: 'must be a Hash' }.freeze

    attr_reader :_schema

    def initialize(schema: BLANK_HASH, inclusive: false)
      @_schema = wrap_keys_and_values(schema)
      @inclusive = inclusive
      freeze
    end

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
        self.class.new(schema: _schema.merge(wrap_keys_and_values(hash)), inclusive: @inclusive)
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

      self.class.new(schema: merge_rightmost_keys(_schema, other_schema), inclusive: @inclusive)
    end

    def &(other)
      raise ArgumentError, "expected a HashClass, got #{other.class}" unless other.is_a?(HashClass)

      intersected_keys = other._schema.keys & _schema.keys
      intersected = intersected_keys.each.with_object({}) do |k, memo|
        memo[k] = other.at_key(k)
      end

      self.class.new(schema: intersected, inclusive: @inclusive)
    end

    def tagged_by(key, *types)
      TaggedHash.new(self, key, types)
    end

    def inclusive
      self.class.new(schema: _schema, inclusive: true)
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
        return result.invalid(errors: 'must be a Hash') unless result.value.is_a?(::Hash)
        return result unless _schema.any?

        input = result.value
        field_result = BLANK_RESULT.dup
        output = _schema.each.with_object({}) do |(key, field), ret|
          key_s = key.to_sym
          if input.key?(key_s)
            r = field.call(field_result.reset(input[key_s]))
            ret[key_s] = r.value if r.valid?
          elsif !key.optional?
            r = field.call(BLANK_RESULT)
            ret[key_s] = r.value if r.valid?
          end
        end
        result.valid(output)
      end
      FilteredHash.new(self, relaxed_to_optional, op)
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
      return result.invalid(errors: NOT_A_HASH) unless result.value.is_a?(::Hash)
      return result unless _schema.any?

      input = result.value
      errors = nil # Do not allocate errors unless needed
      output = @inclusive ? input.dup : {}
      field_result = Result.valid(nil)

      _schema.each do |key, field|
        key_s = key.to_key
        if input.key?(key_s)
          r = field.call(field_result.reset(input[key_s]))
          output[key_s] = r.value
          unless r.valid?
            errors ||= {}
            errors[key_s] = r.errors
          end
        elsif !key.optional?
          r = field.call(BLANK_RESULT)
          output[key_s] = r.value unless r.value == Undefined
          unless r.valid?
            errors ||= {}
            errors[key_s] = r.errors
          end
        end
      end

      errors ? result.invalid(output, errors:) : result.valid(output)
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

      other._schema.all? do |other_key, other_field|
        mine_key, mine_field = _schema.find { |k, _| k.eql?(other_key) }
        if mine_field
          Plumb::Subtyping.subtype?(mine_field, other_field) &&
            (other_key.optional? || !mine_key.optional?)
        else
          other_key.optional?
        end
      end
    end

    private

    # A non-inclusive structured Hash emits exactly its declared keys, so it is
    # a subtype of a `key_type => value_type` map when every key fits `key_type`
    # and every value type is a subtype of `value_type`. An inclusive or empty
    # (any-Hash) schema may carry arbitrary entries that don't fit the map.
    def hashmap_subtype?(other)
      return false if @inclusive || _schema.empty?

      key_type, value_type = other.children
      _schema.all? do |key, field|
        Plumb::Subtyping.subtype?(Composable.wrap(key.to_key), key_type) &&
          Plumb::Subtyping.subtype?(field, value_type)
      end
    end

    # This schema with every key relaxed to optional (same value types). Used as
    # the output type of #filtered, which may drop any field.
    def relaxed_to_optional
      relaxed = _schema.each_with_object({}) do |(key, type), h|
        h[Key.new(key.to_key, optional: true)] = type
      end
      self.class.new(schema: relaxed)
    end

    def _inspect
      %(Hash[#{_schema.map { |(k, v)| [k.inspect, v.inspect].join(': ') }.join(', ')}])
    end

    def wrap_keys_and_values(hash)
      hash.each.with_object({}) do |(k, v), ret|
        ret[Key.wrap(k)] = Composable.wrap(v)
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

  # The typed node returned by HashClass#filtered. It is a Transform — so #>>
  # treats it as a conversion (subtype by its output, accepted by its input) and
  # it bypasses the strict composition check — declaring `input_type` as the
  # filtered schema and `output_type` as that schema with all keys optional. But
  # unlike a plain Transform it does NOT strict-validate its input: #call runs
  # the lenient filter, which accepts any Hash and drops invalid/missing/extra
  # fields.
  class FilteredHash < Transform
    # Naming derives #node_name when Composable is *included* (on Transform), so
    # the subclass would otherwise inherit :transform.
    def node_name = :filtered_hash

    def call(result) = transform_proc.call(result)

    private def _inspect = "#{input_type.inspect}.filtered"
  end
end

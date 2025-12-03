# frozen_string_literal: true

require 'plumb/composable'
require 'plumb/key'
require 'plumb/static_class'
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
      Step.new(op, [_inspect, 'filtered'].join('.'))
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
      other.is_a?(self.class) && other._schema == _schema
    end

    private

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
end

# frozen_string_literal: true

require 'date'
require 'plumb/visitor_handlers'

module Plumb
  class JSONSchemaVisitor
    include VisitorHandlers

    # Raised when a value that has no JSON-native representation would end up in
    # the generated schema. Register a handler (via `.on(...)`) that converts the
    # offending type to a JSON-native value to resolve it.
    InvalidJSONValueError = Class.new(StandardError)

    TYPE = 'type'
    PROPERTIES = 'properties'
    REQUIRED = 'required'
    DEFAULT = 'default'
    ANY_OF = 'anyOf'
    ALL_OF = 'allOf'
    NOT = 'not'
    ENUM = 'enum'
    CONST = 'const'
    ITEMS = 'items'
    PATTERN = 'pattern'
    MINIMUM = 'minimum'
    MAXIMUM = 'maximum'
    MIN_ITEMS = 'minItems'
    MAX_ITEMS = 'maxItems'
    MIN_LENGTH = 'minLength'
    MAX_LENGTH = 'maxLength'
    FORMAT = 'format'
    FORMAT_MINIMUM = 'formatMinimum'
    FORMAT_MAXIMUM = 'formatMaximum'
    FORMAT_EXCLUSIVE_MAXIMUM = 'formatExclusiveMaximum'
    ENVELOPE = {
      '$schema' => 'https://json-schema.org/draft-08/schema#'
    }.freeze

    def self.call(node, root: true)
      data = new.visit(node)
      data = ENVELOPE.merge(data) if root
      normalize_json(data)
    end

    # Recursively normalize the generated schema into JSON-native values and
    # fail loudly on anything that has no JSON representation.
    # Symbols are coerced to strings; everything that isn't a JSON-native value
    # raises, so the user knows they need to register a custom visitor handler.
    def self.normalize_json(value)
      case value
      when ::Hash
        value.each_with_object({}) do |(key, val), hash|
          hash[normalize_json(key)] = normalize_json(val)
        end
      when ::Array
        value.map { |val| normalize_json(val) }
      when ::Symbol
        value.to_s
      when ::String, ::Numeric, true, false, nil
        value
      else
        raise InvalidJSONValueError,
              "#{value.class} value #{value.inspect} cannot be serialized to JSON Schema. " \
              'Register a Plumb::JSONSchemaVisitor.on(...) handler that converts it to a JSON-native value.'
      end
    end

    # Some rules that are dependent on combinations of aggregates keys
    # Ex. if `format` is set, `pattern` should be removed
    private def clean_up_after_visit(props)
      props.delete(PATTERN) if props.key?(FORMAT)
      props
    end

    private def stringify_keys(hash) = hash.transform_keys(&:to_s)

    on(:any) do |_node, props|
      props
    end

    on(:pipeline) do |node, props|
      visit_children(node, props)
    end

    on(:step) do |node, props|
      props.merge(stringify_keys(node._metadata))
    end

    on(:interface) do |_node, props|
      props
    end

    # Trying to visit the deferred could go into infinite recursion
    # if a type is deferring to itself
    # Not clear what deferred types would mean for JSON Schema anyway.
    on(:deferred) do |node, props|
      props
    end

    on(:hash) do |node, props|
      props.merge(
        TYPE => 'object',
        PROPERTIES => node._schema.each_with_object({}) do |(key, value), hash|
          hash[key.to_s] = visit(value)
        end,
        REQUIRED => node._schema.reject { |key, _value| key.optional? }.keys.map(&:to_s)
      )
    end

    on(:data) do |node, props|
      visit_name :hash, node._schema, props
    end

    # A refinement (`And`): both sides describe the SAME value. Build from the
    # input side and fold in the output side when it shares the input's type (a
    # constraint such as `pattern`/`minimum`/`format`), or when the input is
    # untyped. Both sides are validators over one value, so both are visited.
    on(:and) do |node, props|
      left, right = node.children.map { |c| visit(c) }
      if !left.key?(TYPE) || left[TYPE] == right[TYPE]
        type = left[TYPE] || right[TYPE]
        merged = props.merge(left).merge(right)
        type ? merged.merge(TYPE => type) : merged
      else
        props.merge(left)
      end
    end

    # A conversion (`Transform`) produces a genuinely different value. A JSON
    # Schema describes accepted *inputs*, so it is built from the input side and
    # the output is dropped — and crucially NOT visited, so a transform whose
    # output type has no schema handler (eg. a custom class via #build) is fine.
    # Only when the input is untyped (eg. `Any.transform(::Integer)`) do we fall
    # back to the output type, since that is then all we know.
    on(:transform) do |node, props|
      left = visit(node.input_type)
      return props.merge(left) if left.key?(TYPE)

      props.merge(left).merge(visit(node.output_type))
    end

    # A filtered Hash may drop any field, so its schema is its relaxed
    # (all-optional) output.
    on(:filtered_hash) do |node, props|
      props.merge(visit(node.output_type))
    end

    # A "default" value is usually an "or" of expected_value | (undefined >> static_value)
    on(:or) do |node, props|
      left, right = node.children.map { |c| visit(c) }
      any_of = [left, right].uniq.filter(&:any?)
      if any_of.size == 1
        props.merge(any_of.first)
      elsif any_of.size == 2 && (defidx = any_of.index { |p| p.key?(DEFAULT) })
        val = any_of[defidx.zero? ? 1 : 0]
        props.merge(val).merge(DEFAULT => any_of[defidx][DEFAULT])
      else
        props.merge(ANY_OF => any_of)
      end
    end

    on(:not) do |node, props|
      props.merge(NOT => visit_children(node))
    end

    on(:value) do |node, props|
      value = node.children.first
      props = case value
              when ::String, ::Symbol, ::Numeric
                props.merge(CONST => value)
              else
                props
              end

      visit(value, props)
    end

    on(:undefined) do |_node, props|
      props
    end

    on(:static) do |node, props|
      # Set const AND default
      # to emulate static values
      value = node.children.first
      props = case value
              when ::String, ::Symbol, ::Numeric
                props.merge(CONST => value, DEFAULT => value)
              else
                props
              end

      visit(value, props)
    end

    on(:policy) do |node, props|
      props = visit_children(node, props)
      method_name = :"visit_#{node.policy_name}_policy"
      if respond_to?(method_name)
        send(method_name, node, props)
      else
        props
      end
    end

    on(:attribute_value_match) do |node, props|
      method_name = :"visit_with_#{node.attr_name}_attribute"
      if respond_to?(method_name)
        send(method_name, node, props)
      else
        props
      end
    end

    on(:options_policy) do |node, props|
      # Only an Array argument maps to `enum`. Any other argument was delegated
      # to a Match constraint by the policy, so its schema (eg. `minimum`/
      # `maximum` for a Range) has already been built by visiting the children.
      node.arg.is_a?(::Array) ? props.merge(ENUM => node.arg) : props
    end

    on(:with_size_attribute) do |node, props|
      opts = visit(node.type)
      value = node.value

      case opts[TYPE]
      when 'array'
        case value
        when Range
          opts[MIN_ITEMS] = value.min if value.begin
          opts[MAX_ITEMS] = value.max if value.end
        when Numeric
          opts[MIN_ITEMS] = value
          opts[MAX_ITEMS] = value
        end
      when 'string'
        case value
        when Range
          opts[MIN_LENGTH] = value.min if value.begin
          opts[MAX_LENGTH] = value.max if value.end
        when Numeric
          opts[MIN_LENGTH] = value
          opts[MAX_LENGTH] = value
        end
      end

      props.merge(opts)
    end

    on(:excluded_from_policy) do |node, props|
      props.merge(NOT => { ENUM => node.arg })
    end

    on(Proc) do |_node, props|
      props
    end

    on(:match) do |node, props|
      # Set const if primitive
      matcher = node.children.first
      props = case matcher
              when ::String, ::Symbol, ::Numeric
                props.merge(CONST => matcher)
              when ::Date, ::Time # also covers ::DateTime
                props.merge(CONST => matcher.iso8601)
              else
                props
              end

      visit(matcher, props)
    end

    on(:boolean) do |_node, props|
      props.merge(TYPE => 'boolean')
    end

    on(:uuid) do |_node, props|
      props.merge(TYPE => 'string', FORMAT => 'uuid')
    end

    on(:email) do |_node, props|
      props.except(PATTERN).merge(TYPE => 'string', FORMAT => 'email')
    end

    on(::String) do |_node, props|
      props.merge(TYPE => 'string')
    end

    on(::Integer) do |_node, props|
      props.merge(TYPE => 'integer')
    end

    on(::Numeric) do |_node, props|
      props.merge(TYPE => 'number')
    end

    on(::BigDecimal) do |_node, props|
      props.merge(TYPE => 'number')
    end

    on(::Float) do |_node, props|
      props.merge(TYPE => 'number')
    end

    on(::TrueClass) do |_node, props|
      props.merge(TYPE => 'boolean')
    end

    on(::NilClass) do |_node, props|
      props.merge(TYPE => 'null')
    end

    on(::FalseClass) do |_node, props|
      props.merge(TYPE => 'boolean')
    end

    on(::Regexp) do |node, props|
      props.merge(PATTERN => node.source, TYPE => props[TYPE] || 'string')
    end

    on(::Range) do |node, props|
      element = node.begin || node.end
      opts = visit(element.class)
      case element
      when ::Numeric
        opts[MINIMUM] = node.min if node.begin
        opts[MAXIMUM] = node.max if node.end
      when ::Date, ::Time # also covers ::DateTime
        # JSON Schema has no native min/max for date/time strings, so use the
        # `formatMinimum`/`formatMaximum` keywords (the format-assertion
        # convention also supported by ajv) alongside `format`.
        opts[FORMAT_MINIMUM] = node.begin.iso8601 if node.begin
        if node.end
          if node.exclude_end?
            opts[FORMAT_EXCLUSIVE_MAXIMUM] = node.end.iso8601
          else
            opts[FORMAT_MAXIMUM] = node.end.iso8601
          end
        end
      end
      props.merge(opts)
    end

    on(::Time) do |_node, props|
      props.merge(TYPE => 'string', FORMAT => 'date-time')
    end

    on(::Date) do |_node, props|
      props.merge(TYPE => 'string', FORMAT => 'date')
    end

    on(::URI::Generic) do |_node, props|
      props.merge(TYPE => 'string', FORMAT => 'uri')
    end

    on(::URI::HTTP) do |_node, props|
      props.merge(TYPE => 'string', FORMAT => 'uri')
    end

    on(::URI::File) do |_node, props|
      props.merge(TYPE => 'string', FORMAT => 'uri')
    end

    on(::Hash) do |_node, props|
      props.merge(TYPE => 'object')
    end

    on(::Array) do |_node, props|
      props.merge(TYPE => 'array')
    end

    on(:metadata) do |node, props|
      #  TODO: here we should filter out the metadata that is not relevant for JSON Schema
      props = props.merge(stringify_keys(node.metadata))
      props.merge(visit(node.type, props))
    end

    on(:hash_map) do |node, _props|
      {
        TYPE => 'object',
        'patternProperties' => {
          '.*' => visit(node.children[1])
        }
      }
    end

    on(:filtered_hash_map) do |node, _props|
      {
        TYPE => 'object',
        'patternProperties' => {
          '.*' => visit(node.children[1])
        }
      }
    end

    on(:array) do |node, _props|
      items_props = visit_children(node)
      { TYPE => 'array', ITEMS => items_props }
    end

    on(:stream) do |node, _props|
      items_props = visit_children(node)
      { TYPE => 'array', ITEMS => items_props }
    end

    on(:tuple) do |node, _props|
      items = node.children.map { |t| visit(t) }
      { TYPE => 'array', 'prefixItems' => items }
    end

    on(:tagged_hash) do |node, _props|
      required = Set.new
      result = {
        TYPE => 'object',
        PROPERTIES => {}
      }

      key = node.key.to_s
      children = node.children.map { |c| visit(c) }
      key_enum =  children.map { |c| c[PROPERTIES][key][CONST] }
      key_type =  children.map { |c| c[PROPERTIES][key][TYPE] }
      required << key
      result[PROPERTIES][key] = { TYPE => key_type.first, ENUM => key_enum }
      result[ALL_OF] = children.map do |child|
        child_prop = child[PROPERTIES][key]

        {
          'if' => {
            PROPERTIES => { key => child_prop.slice(CONST, TYPE) }
          },
          'then' => child.except(TYPE)
        }
      end

      result.merge(REQUIRED => required.to_a)
    end

  end
end

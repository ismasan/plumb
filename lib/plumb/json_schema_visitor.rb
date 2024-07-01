# frozen_string_literal: true

require 'plumb/visitor_handlers'

module Plumb
  class JSONSchemaVisitor
    include VisitorHandlers

    TYPE = 'type'
    PROPERTIES = 'properties'
    REQUIRED = 'required'
    DEFAULT = 'default'
    ANY_OF = 'anyOf'
    ALL_OF = 'allOf'
    ENUM = 'enum'
    CONST = 'const'
    ITEMS = 'items'
    PATTERN = 'pattern'
    MINIMUM = 'minimum'
    MAXIMUM = 'maximum'

    def self.call(type)
      { 
        '$schema' => 'https://json-schema.org/draft-08/schema#',
      }.merge(new.visit(type))
    end

    private def stringify_keys(hash) = hash.transform_keys(&:to_s)

    on(:any) do |type, props|
      props
    end

    on(:pipeline) do |type, props|
      visit(type.type, props)
    end

    on(:step) do |type, props|
      props.merge(stringify_keys(type._metadata))
    end

    on(:hash) do |type, props|
      props.merge(
        TYPE => 'object',
        PROPERTIES => type._schema.each_with_object({}) do |(key, value), hash|
          hash[key.to_s] = visit(value)
        end,
        REQUIRED => type._schema.select { |key, value| !key.optional? }.keys.map(&:to_s)
      )
    end

    on(:and) do |type, props|
      left = visit(type.left)
      right = visit(type.right)
      type = right[TYPE] || left[TYPE]
      props = props.merge(left).merge(right)
      props = props.merge(TYPE => type) if type
      props
    end

    # A "default" value is usually an "or" of expected_value | (undefined >> static_value)
    on(:or) do |type, props|
      left = visit(type.left)
      right = visit(type.right)
      any_of = [left, right].uniq
      if any_of.size == 1
        props.merge(left)
      elsif any_of.size == 2 && (defidx = any_of.index { |p| p.key?(DEFAULT) })
        val = any_of[defidx == 0 ? 1 : 0]
        props.merge(val).merge(DEFAULT => any_of[defidx][DEFAULT])
      else
        props.merge(ANY_OF => any_of)
      end
    end

    on(:value) do |type, props|
      props = case type.value
      when ::String, ::Symbol, ::Numeric
        props.merge(CONST => type.value)
      else
        props
      end

      visit(type.value, props)
    end

    on(:transform) do |type, props|
      visit(type.target_type, props)
    end

    on(:undefined) do |type, props|
      props
    end

    on(:static) do |type, props|
      props = case type.value
      when ::String, ::Symbol, ::Numeric
        props.merge(CONST => type.value, DEFAULT => type.value)
      else
        props
      end

      visit(type.value, props)
    end

    on(:rules) do |type, props|
      type.rules.reduce(props) do |acc, rule|
        acc.merge(visit(rule))
      end
    end

    on(:rule_included_in) do |type, props|
      props.merge(ENUM => type.arg_value)
    end

    on(:match) do |type, props|
      visit(type.matcher, props)
    end

    on(:boolean) do |type, props|
      props.merge(TYPE => 'boolean')
    end

    on(::String) do |type, props|
      props.merge(TYPE => 'string')
    end

    on(::Integer) do |type, props|
      props.merge(TYPE => 'integer')
    end

    on(::Numeric) do |type, props|
      props.merge(TYPE => 'number')
    end

    on(::BigDecimal) do |type, props|
      props.merge(TYPE => 'number')
    end

    on(::Float) do |type, props|
      props.merge(TYPE => 'number')
    end

    on(::TrueClass) do |type, props|
      props.merge(TYPE => 'boolean')
    end

    on(::NilClass) do |type, props|
      props.merge(TYPE => 'null')
    end

    on(::FalseClass) do |type, props|
      props.merge(TYPE => 'boolean')
    end

    on(::Regexp) do |type, props|
      props.merge(PATTERN => type.source)
    end

    on(::Range) do |type, props|
      opts = {}
      opts[MINIMUM] = type.min if type.begin
      opts[MAXIMUM] = type.max if type.end
      props.merge(opts)
    end

    on(:metadata) do |type, props|
      # TODO: here we should filter out the metadata that is not relevant for JSON Schema
      props.merge(stringify_keys(type.metadata))
    end

    on(:hash_map) do |type, props|
      {
        TYPE => 'object',
        'patternProperties' => {
          '.*' => visit(type.value_type)
        }
      }
    end

    on(:build) do |type, props|
      visit(type.type, props)
    end

    on(:array) do |type, props|
      items = visit(type.element_type)
      { TYPE => 'array', ITEMS => items }
    end

    on(:tuple) do |type, props|
      items = type.types.map { |t| visit(t) }
      { TYPE => 'array', 'prefixItems' => items }
    end

    on(:tagged_hash) do |type, props|
      required = Set.new
      result = {
        TYPE => 'object',
        PROPERTIES => {}
      }

      key = type.key.to_s
      children  = type.types.map { |c| visit(c) }
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

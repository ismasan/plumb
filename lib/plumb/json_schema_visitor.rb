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

    def self.call(node)
      {
        '$schema' => 'https://json-schema.org/draft-08/schema#'
      }.merge(new.visit(node))
    end

    private def stringify_keys(hash) = hash.transform_keys(&:to_s)

    on(:any) do |_node, props|
      props
    end

    on(:pipeline) do |node, props|
      visit(node.type, props)
    end

    on(:step) do |node, props|
      props.merge(stringify_keys(node._metadata))
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

    on(:and) do |node, props|
      left = visit(node.left)
      right = visit(node.right)
      type = right[TYPE] || left[TYPE]
      props = props.merge(left).merge(right)
      props = props.merge(TYPE => type) if type
      props
    end

    # A "default" value is usually an "or" of expected_value | (undefined >> static_value)
    on(:or) do |node, props|
      left = visit(node.left)
      right = visit(node.right)
      any_of = [left, right].uniq
      if any_of.size == 1
        props.merge(left)
      elsif any_of.size == 2 && (defidx = any_of.index { |p| p.key?(DEFAULT) })
        val = any_of[defidx.zero? ? 1 : 0]
        props.merge(val).merge(DEFAULT => any_of[defidx][DEFAULT])
      else
        props.merge(ANY_OF => any_of)
      end
    end

    on(:not) do |node, props|
      props.merge('not' => visit(node.step))
    end

    on(:value) do |node, props|
      props = case node.value
              when ::String, ::Symbol, ::Numeric
                props.merge(CONST => node.value)
              else
                props
              end

      visit(node.value, props)
    end

    on(:transform) do |node, props|
      visit(node.target_type, props)
    end

    on(:undefined) do |_node, props|
      props
    end

    on(:static) do |node, props|
      props = case node.value
              when ::String, ::Symbol, ::Numeric
                props.merge(CONST => node.value, DEFAULT => node.value)
              else
                props
              end

      visit(node.value, props)
    end

    on(:rules) do |node, props|
      node.rules.reduce(props) do |acc, rule|
        acc.merge(visit(rule))
      end
    end

    on(:rule_included_in) do |node, props|
      props.merge(ENUM => node.arg_value)
    end

    on(:match) do |node, props|
      visit(node.matcher, props)
    end

    on(:boolean) do |_node, props|
      props.merge(TYPE => 'boolean')
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
      props.merge(PATTERN => node.source)
    end

    on(::Range) do |node, props|
      opts = {}
      opts[MINIMUM] = node.min if node.begin
      opts[MAXIMUM] = node.max if node.end
      props.merge(opts)
    end

    on(:metadata) do |node, props|
      #  TODO: here we should filter out the metadata that is not relevant for JSON Schema
      props.merge(stringify_keys(node.metadata))
    end

    on(:hash_map) do |node, _props|
      {
        TYPE => 'object',
        'patternProperties' => {
          '.*' => visit(node.value_type)
        }
      }
    end

    on(:build) do |node, props|
      visit(node.type, props)
    end

    on(:array) do |node, _props|
      items = visit(node.element_type)
      { TYPE => 'array', ITEMS => items }
    end

    on(:tuple) do |node, _props|
      items = node.types.map { |t| visit(t) }
      { TYPE => 'array', 'prefixItems' => items }
    end

    on(:tagged_hash) do |node, _props|
      required = Set.new
      result = {
        TYPE => 'object',
        PROPERTIES => {}
      }

      key = node.key.to_s
      children = node.types.map { |c| visit(c) }
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

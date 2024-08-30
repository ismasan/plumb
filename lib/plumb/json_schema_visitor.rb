# frozen_string_literal: true

require 'date'
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
    ENVELOPE = {
      '$schema' => 'https://json-schema.org/draft-08/schema#'
    }.freeze

    def self.call(node, root: true)
      data = new.visit(node)
      return data unless root

      ENVELOPE.merge(data)
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

    on(:and) do |node, props|
      left, right = node.children.map { |c| visit(c) }
      type = right[TYPE] || left[TYPE]
      props = props.merge(left).merge(right)
      props = props.merge(TYPE => type) if type
      props
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

    on(:transform) do |node, props|
      visit_children(node, props)
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

    on(:options_policy) do |node, props|
      props.merge(ENUM => node.arg)
    end

    on(:size_policy) do |node, props|
      opts = {}
      case props[TYPE]
      when 'array'
        case node.arg
        when Range
          opts[MIN_ITEMS] = node.arg.min if node.arg.begin
          opts[MAX_ITEMS] = node.arg.max if node.arg.end
        when Numeric
          opts[MIN_ITEMS] = node.arg
          opts[MAX_ITEMS] = node.arg
        end
      when 'string'
        case node.arg
        when Range
          opts[MIN_LENGTH] = node.arg.min if node.arg.begin
          opts[MAX_LENGTH] = node.arg.max if node.arg.end
        when Numeric
          opts[MIN_LENGTH] = node.arg
          opts[MAX_LENGTH] = node.arg
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
      if element.is_a?(::Numeric)
        opts[MINIMUM] = node.min if node.begin
        opts[MAXIMUM] = node.max if node.end
      end
      props.merge(opts)
    end

    on(::Time) do |_node, props|
      props.merge(TYPE => 'string', FORMAT => 'date-time')
    end

    on(::Date) do |_node, props|
      props.merge(TYPE => 'string', FORMAT => 'date')
    end

    on(::Hash) do |_node, props|
      props.merge(TYPE => 'object')
    end

    on(::Array) do |_node, props|
      props.merge(TYPE => 'array')
    end

    on(:metadata) do |node, props|
      #  TODO: here we should filter out the metadata that is not relevant for JSON Schema
      props.merge(stringify_keys(node.metadata))
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

    on(:build) do |node, props|
      visit_children(node, props)
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

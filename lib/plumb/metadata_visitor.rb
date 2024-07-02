# frozen_string_literal: true

require 'plumb/visitor_handlers'

module Plumb
  class MetadataVisitor
    include VisitorHandlers

    def self.call(node)
      new.visit(node)
    end

    def on_missing_handler(node, props, method_name)
      return props.merge(type: node) if node.class == Class

      puts "Missing handler for #{node.inspect} with props #{node.inspect} and method_name :#{method_name}"
      props
    end

    on(:undefined) do |_node, props|
      props
    end

    on(:any) do |_node, props|
      props
    end

    on(:pipeline) do |node, props|
      visit(node.type, props)
    end

    on(:step) do |node, props|
      props.merge(node._metadata)
    end

    on(::Regexp) do |node, props|
      props.merge(pattern: node)
    end

    on(::Range) do |node, props|
      props.merge(match: node)
    end

    on(:match) do |node, props|
      visit(node.matcher, props)
    end

    on(:hash) do |_node, props|
      props.merge(type: Hash)
    end

    on(:and) do |node, props|
      left = visit(node.left)
      right = visit(node.right)
      type = right[:type] || left[:type]
      props = props.merge(left).merge(right)
      props = props.merge(type: type) if type
      props
    end

    on(:or) do |node, props|
      child_metas = [visit(node.left), visit(node.right)]
      types = child_metas.map { |child| child[:type] }.flatten.compact
      types = types.first if types.size == 1
      child_metas.reduce(props) do |acc, child|
        acc.merge(child)
      end.merge(type: types)
    end

    on(:value) do |node, props|
      visit(node.value, props)
    end

    on(:transform) do |node, props|
      props.merge(type: node.target_type)
    end

    on(:static) do |node, props|
      props.merge(static: node.value)
    end

    on(:rules) do |node, props|
      node.rules.reduce(props) do |acc, rule|
        acc.merge(rule.name => rule.arg_value)
      end
    end

    on(:boolean) do |_node, props|
      props.merge(type: 'boolean')
    end

    on(:metadata) do |node, props|
      props.merge(node.metadata)
    end

    on(:hash_map) do |_node, props|
      props.merge(type: Hash)
    end

    on(:build) do |node, props|
      visit(node.type, props)
    end

    on(:array) do |_node, props|
      props.merge(type: Array)
    end

    on(:tuple) do |_node, props|
      props.merge(type: Array)
    end

    on(:tagged_hash) do |_node, props|
      props.merge(type: Hash)
    end
  end
end

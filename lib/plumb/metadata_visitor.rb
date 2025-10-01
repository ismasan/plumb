# frozen_string_literal: true

require 'plumb/visitor_handlers'

module Plumb
  class MetadataVisitor
    include VisitorHandlers

    def self.call(node)
      new.visit(node)
    end

    def on_missing_handler(node, props, _method_name)
      return props.merge(type: node) if node.instance_of?(Class)

      return props unless node.respond_to?(:children)

      node.children.reduce(props) do |acc, child|
        visit(child, acc)
      end
    end

    on(:step) do |node, props|
      props.merge(node._metadata)
    end

    on(::Regexp) do |node, props|
      props.merge(pattern: node, type: props[:type] || String)
    end

    on(::Range) do |node, props|
      type = props[:type] || (node.begin || node.end).class
      props.merge(match: node, type:)
    end

    on(:hash) do |_node, props|
      props.merge(type: Hash)
    end

    on(:and) do |node, props|
      left, right = node.children.map { |child| visit(child) }
      type = right[:type] || left[:type]
      props = props.merge(left).merge(right)
      props = props.merge(type:) if type
      props
    end

    on(:or) do |node, props|
      child_metas = node.children.map { |child| visit(child) }
      types = child_metas.map { |child| child[:type] }.flatten.compact
      types = types.first if types.size == 1
      child_metas.reduce(props) do |acc, child|
        acc.merge(child)
      end.merge(type: types)
    end

    on(:static) do |node, props|
      value = node.children[0]
      type = value.is_a?(Class) ? value : value.class
      props.merge(static: value, type:)
    end

    on(:policy) do |node, props|
      props = visit(node.children[0], props)
      props = props.merge(node.policy_name => node.arg) unless node.arg == Plumb::Undefined
      props
    end

    on(:boolean) do |_node, props|
      props.merge(type: 'boolean')
    end

    on(:metadata) do |node, props|
      props = visit(node.type, props)
      props.merge(node.metadata)
    end

    on(:hash_map) do |_node, props|
      props.merge(type: Hash)
    end

    on(:array) do |_node, props|
      props.merge(type: Array)
    end

    on(:stream) do |_node, props|
      props.merge(type: Enumerator)
    end

    on(:tuple) do |_node, props|
      props.merge(type: Array)
    end

    on(:tagged_hash) do |_node, props|
      props.merge(type: Hash)
    end

    on(Proc) do |_node, props|
      props
    end
  end
end

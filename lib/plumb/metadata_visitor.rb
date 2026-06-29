# frozen_string_literal: true

require 'plumb/visitor_handlers'

module Plumb
  class MetadataVisitor
    include VisitorHandlers

    def self.call(node)
      new.visit(node)
    end

    def on_missing_handler(node, props, _method_name)
      return props unless node.respond_to?(:children)

      node.children.reduce(props) do |acc, child|
        visit(child, acc)
      end
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

    on(:hash) do |_node, props|
      props
    end

    on(:and) do |node, props|
      left, right = node.children.map { |child| visit(child) }
      props.merge(left).merge(right)
    end

    on(:or) do |node, props|
      node.children
          .map { |child| visit(child) }
          .reduce(props) { |acc, child| acc.merge(child) }
    end

    on(:static) do |node, props|
      props.merge(static: node.children[0])
    end

    on(:policy) do |node, props|
      props = visit(node.children[0], props)
      props = props.merge(node.policy_name => node.arg) unless node.arg == Plumb::Undefined
      props
    end

    on(:boolean) do |_node, props|
      props
    end

    on(:metadata) do |node, props|
      props = visit(node.type, props)
      props.merge(node.metadata)
    end

    on(:hash_map) do |_node, props|
      props
    end

    on(:array) do |_node, props|
      props
    end

    on(:stream) do |_node, props|
      props
    end

    on(:tuple) do |_node, props|
      props
    end

    on(:tagged_hash) do |_node, props|
      props
    end

    on(Proc) do |_node, props|
      props
    end
  end
end

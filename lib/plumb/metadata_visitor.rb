# frozen_string_literal: true

require 'plumb/visitor_handlers'

module Plumb
  # Collects user-provided metadata for a type (via #metadata, custom step
  # metadata, and policy arguments). Any type-bound information (the expected
  # Ruby types, patterns, ranges, static values, etc.) is intentionally NOT
  # collected here — it is described by #input_type / #output_type instead.
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

    on(:hash) do |_node, props|
      props
    end

    on(:never) do |_node, props|
      props
    end

    # A refinement matcher carries its base; any user metadata lives on the base
    # (the matcher itself is type-bound info we don't collect), so follow it.
    on(:constraint) do |node, props|
      node.base ? visit(node.base, props) : props
    end

    on(:and) do |node, props|
      left, right = node.children.map { |child| visit(child) }
      props.merge(left).merge(right)
    end

    # A factored union is transparent for metadata — its wrapped And carries the
    # base + disjunction, so delegate to it.
    on(:refined_union) do |node, props|
      visit(node.type, props)
    end

    on(:function) do |node, props|
      left, right = node.children.map { |child| visit(child) }
      props.merge(left).merge(right)
    end

    on(:or) do |node, props|
      node.children
          .map { |child| visit(child) }
          .reduce(props) { |acc, child| acc.merge(child) }
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

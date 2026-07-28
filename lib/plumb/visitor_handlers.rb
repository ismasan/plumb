# frozen_string_literal: true

module Plumb
  module VisitorHandlers
    # Node names introduced by the type/computation split, each mapped to the name
    # the node was reported under before it existed. `Plumb::Intersection` used to
    # be an `And` and `Plumb::Union` used to be an `Or`, so a visitor written
    # against the old AST defines only `on(:and)` / `on(:or)` — without this it
    # would raise "no handler" on a type it used to understand.
    #
    # Consulted ONLY when the specific handler is absent, so a visitor that does
    # distinguish the two (see JSONSchemaVisitor) keeps full control. Plumb's own
    # visitors register both names explicitly; this is for visitors outside the gem.
    NODE_NAME_FALLBACKS = { intersection: :and, union: :or }.freeze

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def on(node_name, &block)
        name = node_name.is_a?(Symbol) ? node_name : :"#{node_name}_class"
        define_method("visit_#{name}", &block)
      end

      def visit(node, props = BLANK_HASH)
        new.visit(node, props)
      end
    end

    def visit(node, props = BLANK_HASH)
      method_name = if node.respond_to?(:node_name)
                      node.node_name
                    else
                      :"#{(node.is_a?(::Class) ? node : node.class)}_class"
                    end

      clean_up_after_visit visit_name(method_name, node, props)
    end

    def visit_name(method_name, node, props = BLANK_HASH)
      target = :"visit_#{method_name}"

      unless respond_to?(target)
        fallback = NODE_NAME_FALLBACKS[method_name]
        target = :"visit_#{fallback}" if fallback && respond_to?(:"visit_#{fallback}")
      end

      if respond_to?(target)
        send(target, node, props)
      else
        on_missing_handler(node, props, target)
      end
    end

    def on_missing_handler(node, _props, method_name)
      raise "No handler for #{node.inspect} with :#{method_name}"
    end

    def visit_children(node, props = BLANK_HASH)
      node.children.reduce(props) do |acc, child|
        visit(child, acc)
      end
    end

    private def clean_up_after_visit(props) = props
  end
end

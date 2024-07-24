# frozen_string_literal: true

module Plumb
  module VisitorHandlers
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

      visit_name(method_name, node, props)
    end

    def visit_name(method_name, node, props = BLANK_HASH)
      method_name = :"visit_#{method_name}"
      if respond_to?(method_name)
        send(method_name, node, props)
      else
        on_missing_handler(node, props, method_name)
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
  end
end

# frozen_string_literal: true

require 'plumb/policies'

module Plumb
  @policies = Policies.new

  def self.policies
    @policies
  end

  # Register a policy with the given name and block.
  # Optionally define a method on the Composable method to call the policy.
  # Example:
  #   Plumb.policy(:multiply_by, for_type: Integer, helper: true) do |step, factor, &block|
  #     step.transform(Integer) { |number| number * factor }
  #   end
  #
  #  type = Types::Integer.multiply_by(2)
  #  type.parse(10) # => 20
  #
  # @param name [Symbol] the name of the policy
  # @param opts [Hash] options for the policy
  # @yield [Step, Object, &block] the step (type), policy argument, and policy block, if any.
  def self.policy(name, opts = {}, &block)
    name = name.to_sym
    if opts.is_a?(Hash) && block_given?
      for_type = opts[:for_type] || Object
      helper = opts[:helper] || false
    elsif opts.respond_to?(:call) && opts.respond_to?(:for_type) && opts.respond_to?(:helper)
      for_type = opts.for_type
      helper = opts.helper
      block = opts.method(:call)
    else
      raise ArgumentError, 'Expected a block or a hash with :for_type and :helper keys'
    end

    policies.register(for_type, name, block)

    return self unless helper

    if Composable.instance_methods.include?(name)
      raise Policies::MethodAlreadyDefinedError, "Method #{name} is already defined on Composable"
    end

    Composable.define_method(name) do |arg = Undefined, &bl|
      if arg == Undefined
        policy(name, &bl)
      else
        policy(name, arg, &bl)
      end
    end

    self
  end

  def self.decorate(type, &block)
    Decorator.call(type, &block)
  end

  # Recursively resolve the underlying Ruby classes ("base types") of a node.
  #   Types::String             => [String]
  #   Types::String | Integer   => [String, Integer]
  #
  # This is a temporary helper to preserve type-specific policy resolution
  # (see Composable#policy) until proper subtyping checks are implemented.
  def self.resolve_base_types(node)
    return [node] if node.is_a?(::Class)
    return [] unless node.respond_to?(:node_name)

    # A Composable::Node only RE-LABELS the type it wraps, so it has the same base
    # types — the same reason :metadata and :policy resolve through their wrapped
    # type below. It cannot be a `when` branch: its node_name is whatever #as_node
    # was given (:email, :boolean, :uuid, :refined_union, or anything a caller
    # invents), so there is no name to match on.
    #
    # Without this, EVERY #as_node type reported no base types at all — it fell to
    # the `else` branch, and a Node exposes no #children. That silently skipped the
    # build-time checks that treat an empty list as "unknown base, allow":
    # `Types::Email[1..20]` did not raise (though `Types::String[1..20]` does), and
    # neither did `Types::Boolean.transform(:to_sym)`. It also blocked
    # Subtyping.disjoint_atomic?, so `Types::Email & Types::Integer` stayed a
    # runtime intersection instead of collapsing to Never.
    return resolve_base_types(node.type) if node.is_a?(Composable::Node)

    case node.node_name
    when :or, :union
      node.children.flat_map { |child| resolve_base_types(child) }
    when :function
      resolve_base_types(node.output_type)
    when :intersection
      # An Intersection IS its own #output_type, so following that would recurse
      # forever. It narrows a single value, so its base types are its LEFT's —
      # `String.where(size: 1..3)` is still a String.
      resolve_base_types(node.children[0])
    when :and
      # A composition resolves through what it PRODUCES. And#output_type already
      # encodes whether the right side narrowed the left's output or replaced it,
      # so deferring to it keeps that rule in one place.
      resolve_base_types(node.output_type)
    when :constraint
      # A refinement matcher carries its base type — resolve that (eg.
      # `Integer[1..10]` => [Integer], `User.check {}` => the User's base types).
      return resolve_base_types(node.base) if node.base

      matcher = node.children.first
      case matcher
      when ::Class then [matcher]
      when ::Regexp then [::String]
      when ::Range then [(matcher.begin || matcher.end).class]
      else [matcher.class]
      end
    when :array, :tuple then [::Array]
    when :hash, :hash_map, :tagged_hash, :filtered_hash, :filtered_hash_map then [::Hash]
    when :stream then [::Enumerator]
    when :static
      value = node.children.first
      [value.is_a?(::Class) ? value : value.class]
    when :policy
      resolve_base_types(node.children.first)
    when :metadata
      resolve_base_types(node.type)
    else
      node.respond_to?(:children) ? node.children.flat_map { |child| resolve_base_types(child) } : []
    end
  end
end

require 'plumb/result'
require 'plumb/type_registry'
require 'plumb/composable'
require 'plumb/any_class'
require 'plumb/never_class'
require 'plumb/conjunction'
require 'plumb/and'
require 'plumb/intersection'
require 'plumb/function'
require 'plumb/encoder'
require 'plumb/implementation'
require 'plumb/pipeline'
require 'plumb/static_class'
require 'plumb/value_class'
require 'plumb/constraint'
require 'plumb/not'
require 'plumb/disjunction'
require 'plumb/or'
require 'plumb/union'
require 'plumb/tuple_class'
require 'plumb/array_class'
require 'plumb/stream_class'
require 'plumb/hash_class'
require 'plumb/range_class'
require 'plumb/interface_class'
require 'plumb/attributes'
require 'plumb/subtyping'
require 'plumb/optimizer'
require 'plumb/types'
require 'plumb/codec'
require 'plumb/json_schema_visitor'
require 'plumb/decorator'

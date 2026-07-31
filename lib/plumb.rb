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
  # The base class to report for a matcher that compares VALUES — a literal, a
  # Range endpoint, a Static's value.
  #
  # Numerics compare equal across their classes (`5 == 5.0`) and Ranges of them
  # match across classes too (`(1..10) === 2.5`), so a numeric value describes
  # Numeric rather than only its own class. Reporting Integer would let
  # Subtyping.disjoint_atomic? call `Types::Any[5]` and Types::Float disjoint and
  # sink their intersection to Never, though `5.0` satisfies both.
  def self.value_base_class(value)
    value.is_a?(::Numeric) ? ::Numeric : value.class
  end

  def self.resolve_base_types(node)
    return [node] if node.is_a?(::Class)
    return [] unless node.respond_to?(:node_name)

    # A transparent wrapper (Policy / Metadata / #as_node Node) only RE-LABELS the type
    # it wraps, so it has the same base types. Peeled here rather than per branch: a
    # Node's node_name is whatever #as_node was given, so it cannot be a `when` at all,
    # and every #as_node type would report NO base types — which callers read as
    # "unknown base, allow", silently skipping build-time checks like
    # `Types::Email[1..20]`.
    unwrapped = Plumb::Subtyping.unwrap_transparent(node)
    return resolve_base_types(unwrapped) unless unwrapped.equal?(node)

    case node.node_name
    when :or, :union
      node.children.flat_map { |child| resolve_base_types(child) }
    when :function
      resolve_base_types(node.output_type)
    when :intersection
      # A meet narrows a single value, so its base types are its LEFT's —
      # `String.where(size: 1..3)` is still a String.
      resolve_base_types(node.children[0])
    when :and
      # Descend into whichever side carries the resulting type: a value-preserving right
      # NARROWS what the left produces, a converting right REPLACES it.
      #
      # Deliberately NOT `node.output_type`, which encodes the same rule but is not
      # guaranteed to be a smaller node — for `Array[<record with a coercing field>]
      # .where(size: 1..)` it is a DIFFERENT And whose own output type is itself, so
      # following it ping-pongs until the stack blows. A child always terminates.
      left, right = node.children
      resolve_base_types(Plumb::Subtyping.value_preserving?(right) ? left : right)
    when :constraint
      # A refinement matcher carries its base type — resolve that (eg.
      # `Integer[1..10]` => [Integer], `User.check {}` => the User's base types).
      return resolve_base_types(node.base) if node.base

      matcher = node.children.first
      case matcher
      when ::Class then [matcher]
      # `Regexp#===` coerces, so a pattern matches Symbols as well as Strings
      # (`/x/ === :xyz` is true). Reporting only String would let callers treat a
      # pattern as String-only — eg. an Interface check that a Symbol fails.
      when ::Regexp then [::String, ::Symbol]
      when ::Range then [value_base_class(matcher.begin || matcher.end)]
      else [value_base_class(matcher)]
      end
    when :array, :tuple then [::Array]
    when :hash, :hash_map, :tagged_hash, :filtered_hash, :filtered_hash_map then [::Hash]
    when :stream then [::Enumerator]
    when :range then [::Range]
    when :not
      # A negation describes the COMPLEMENT of what it wraps — every value except
      # those. That is not expressible as a list of base classes (and the wrapped
      # type's own classes are precisely the ones excluded), so report "unknown"
      # and let callers stay conservative.
      []
    when :value
      # A literal matched by `==`. Same rule as :static — the value describes its
      # own class, widened for numerics.
      value = node.children.first
      value.equal?(Undefined) ? [] : [value_base_class(value)]
    when :static
      value = node.children.first
      [value.is_a?(::Class) ? value : value_base_class(value)]
    else
      node.respond_to?(:children) ? node.children.flat_map { |child| resolve_base_types(child) } : []
    end
  end
end

require 'plumb/result'
require 'plumb/type_registry'
require 'plumb/composable'
require 'plumb/typed_step'
require 'plumb/node_mapper'
require 'plumb/covariant_fusion'
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
require 'plumb/mermaid_visitor'
require 'plumb/decorator'

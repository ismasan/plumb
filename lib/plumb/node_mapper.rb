# frozen_string_literal: true

module Plumb
  # THE STRUCTURAL REWRITE PRIMITIVE: map a node's Composable sub-types through a
  # block and rebuild the node around the results — or return the ORIGINAL node
  # when no sub-type changed.
  #
  # That identity guard is the whole reason this is worth having in one place.
  # Every rewriting pass depends on it (an untouched subtree must come back
  # `equal?`, so callers can tell "nothing happened" from "rebuilt identically",
  # and so a no-op pass allocates nothing), and it has to hold uniformly across a
  # dozen node shapes. {Plumb::Decorator} is the cautionary tale: it grew its own
  # `case` over five node types and silently did not recurse into any container or
  # wrapper, so a decorator block never saw a schema's fields.
  #
  # Each node contributes only its own rebuild. Where a node's #children already
  # ARE its Composable sub-types, that is the one-line #with_children hook (the
  # protocol {Plumb::Subtyping.map_children} already used for covariant
  # containers); the nodes whose sub-types live elsewhere — a Metadata's #type, a
  # record's keyed fields — are handled below.
  #
  # DELIBERATELY NOT MAPPED, both matching what every existing pass already does:
  #
  #   - Constraint's #base. A Constraint carries an error message and a label that
  #     it does not expose, so rebuilding one would silently drop a custom
  #     `#check('must start with a')` message.
  #   - Deferred. Forcing it to recurse would loop forever on a self-referential
  #     type. A pass that wants to rewrite through one must tie the knot itself
  #     with its own memo, as Codec::Rewriter does.
  #
  # @example
  #   NodeMapper.map(type) { |child| rewrite(child) }
  module NodeMapper
    module_function

    # @param type [Composable]
    # @yieldparam child [Composable] a Composable sub-type of `type`
    # @return [Composable] `type` itself when nothing changed, else a rebuilt node
    def map(type, &blk)
      case type
      # Two-sided nodes whose #children are exactly their sub-types. `type.class`
      # keeps And vs Intersection (and Or vs Union) across the rebuild.
      when Conjunction, Disjunction, TupleClass, ArrayClass, HashMap, StreamClass, Not, Policy, TaggedHash
        map_children(type, &blk)
      # A Function's #children are [input_type, output_type], but rebuilding it also
      # has to carry the callable, the inspect label and the #== identity.
      when Function
        in_t, out_t = type.children
        l = blk.call(in_t)
        r = blk.call(out_t)
        return type if l.equal?(in_t) && r.equal?(out_t)

        type.class.new(l, r, type.fn, inspect: type.inspect_label, identity: type.identity)
      # Transparent wrappers: the sub-type is #type, not a child.
      when Metadata
        rewrap(type, type.type, blk) { |t| Metadata.new(t, type.metadata) }
      when Composable::Node
        rewrap(type, type.type, blk) { |t| t.as_node(type.node_name, type.args) }
      # A record's sub-types are its keyed fields.
      when HashClass
        map_record(type, &blk)
      else
        type
      end
    end

    # Map `type`'s #children and rebuild via #with_children, preserving identity
    # when every child came back the same.
    def map_children(type, &blk)
      children = type.children
      return type if children.empty?

      mapped = children.map(&blk)
      return type if mapped.each_with_index.all? { |m, i| m.equal?(children[i]) }

      type.with_children(mapped)
    end

    def map_record(type, &blk)
      changed = false
      schema = type._schema.each_with_object({}) do |(key, field), acc|
        mapped = blk.call(field)
        changed ||= !mapped.equal?(field)
        acc[key] = mapped
      end
      changed ? type.class.new(schema:) : type
    end

    # A transparent wrapper: map the wrapped type, keep the wrapper when it did not
    # change, else re-wrap via the block.
    def rewrap(original, inner, blk)
      mapped = blk.call(inner)
      mapped.equal?(inner) ? original : yield(mapped)
    end
  end
end

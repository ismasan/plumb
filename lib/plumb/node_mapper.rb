# frozen_string_literal: true

module Plumb
  # THE STRUCTURAL REWRITE PRIMITIVE: map a node's Composable sub-types through a
  # block and rebuild the node around the results — or return the ORIGINAL node
  # when no sub-type changed.
  #
  # The identity guard is why this belongs in one place: every rewriting pass depends
  # on an untouched subtree coming back `equal?` — so a caller can tell "nothing
  # happened" from "rebuilt identically", and a no-op pass allocates nothing — and it
  # must hold uniformly across a dozen node shapes. {Plumb::Decorator} is the
  # cautionary tale: it grew its own `case` over five node types and silently recursed
  # into no container or wrapper, so a block never saw a schema's fields.
  #
  # Each node contributes only its own rebuild, via the one-line #with_children hook
  # where its #children already ARE its sub-types. Nodes whose sub-types live
  # elsewhere — a Metadata's #type, a record's keyed fields — are handled below.
  #
  # NOT EXHAUSTIVE, deliberately for now: `map` dispatches on a closed class list, so
  # a composite it does not name (`Plumb::Implementation`, or a user-defined one) is
  # returned untouched. Generalizing means a `#map_subtypes(&blk)` hook on each node —
  # the four branches below are the cases a plain `#with_children(array)` cannot
  # express. Worth doing when a third pass needs it.
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
      # Leaf fast path: a Constraint is the most numerous node in any real graph and
      # is deliberately not mapped (see above), so answer it before the class tests.
      return type if type.is_a?(Constraint) || !type.respond_to?(:children)

      case type
      # Nodes whose #children ARE their sub-types: each contributes its own
      # #with_children rebuild and this owns the traversal + identity guard.
      when Conjunction, Disjunction, Function, TupleClass, ArrayClass, HashMap, StreamClass,
           Not, Policy, TaggedHash
        map_children(type, &blk)
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

    # Yields (field, key) — the key so a caller can label the position (see
    # Codec::Rewriter#visit_hash, which builds an error path from it).
    def map_record(type, &blk)
      changed = false
      schema = type._schema.each_with_object({}) do |(key, field), acc|
        mapped = blk.call(field, key)
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

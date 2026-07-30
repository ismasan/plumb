# frozen_string_literal: true

require 'plumb/visitor_handlers'

module Plumb
  # Renders a type composition as a Mermaid `flowchart`, so the flow-control
  # algebra can be visualised. `>>` (And) becomes sequential arrows; `|` (Or)
  # becomes a fork — the predecessor fans out to each alternative.
  #
  # Every `visit` returns `{ entries:, exits: }` — the node ids an incoming
  # arrow should point INTO, and the ids outgoing arrows leave FROM — and
  # accumulates node/edge lines as a side effect (the same stateful pattern
  # JSONSchemaVisitor uses for `$defs`). And connects `left.exits -> right.entries`
  # (a join over a preceding Or's branches); Or unions both branches' entries and
  # exits without a node of its own, so whatever precedes it forks to both.
  #
  # @example
  #   ((A >> B) | (C >> (D | B))).to_mermaid
  class MermaidVisitor
    include VisitorHandlers

    def self.call(node, direction: 'LR')
      new.render(node, direction:)
    end

    def initialize
      @nodes = []
      @edges = []
      @counter = 0
    end

    def render(node, direction: 'LR')
      root = visit(node)
      # A top-level Or has more than one entry; anchor them to a synthetic start
      # node so the diagram reads as a single connected fork.
      entries = root[:entries]
      if entries.size > 1
        @nodes.unshift('start(( ))')
        @edges = entries.map { |e| "start --> #{e}" } + @edges
      end

      lines = ["flowchart #{direction}"]
      (@nodes + @edges).each { |line| lines << "  #{line}" }
      lines.join("\n")
    end

    # Unknown nodes render as a single labeled box rather than raising, so any
    # leaf type (Step, Transform, Constraint, Hash, Array, Boolean, …) degrades
    # gracefully — mirrors MetadataVisitor's recursing override.
    def on_missing_handler(node, _props, _method_name)
      box(node)
    end

    # `>>` — sequence: connect the left's exits to the right's entries.
    on(:and) do |node, _props|
      left = visit(node.children[0])
      right = visit(node.children[1])
      connect(left[:exits], right[:entries])
      { entries: left[:entries], exits: right[:exits] }
    end

    # `|` — fork: no node of its own; union both branches so a preceding step
    # forks to both entries and a following step joins both exits.
    on(:or) do |node, _props|
      left = visit(node.children[0])
      right = visit(node.children[1])
      { entries: left[:entries] + right[:entries], exits: left[:exits] + right[:exits] }
    end

    # Transparent wrappers — recurse into the single inner composition.
    on(:pipeline) do |node, _props|
      visit(node.children[0])
    end

    on(:policy) do |node, _props|
      visit(node.children[0])
    end

    # A Metadata node is a box; its label comes from its own metadata (see #label_for).
    on(:metadata) do |node, _props|
      box(node)
    end

    # A Deferred is (possibly) recursive, so render it as an opaque box and do
    # NOT recurse — mirrors why JSONSchemaVisitor special-cases Deferred.
    on(:deferred) do |node, _props|
      box(node)
    end

    private

    def box(node)
      id = next_id
      @nodes << %(#{id}["#{escape(label_for(node))}"])
      { entries: [id], exits: [id] }
    end

    def connect(from_ids, to_ids)
      from_ids.each do |from|
        to_ids.each { |to| @edges << "#{from} --> #{to}" }
      end
    end

    def next_id
      @counter += 1
      "n#{@counter}"
    end

    # Prefer a node's OWN metadata title/label, else fall back to #inspect. Only
    # nodes that carry metadata directly are consulted — calling #metadata on an
    # And/Or would merge the whole subtree's metadata (wrong for a single box).
    def label_for(node)
      md = own_metadata(node)
      md[:title] || md[:label] || node.inspect
    end

    def own_metadata(node)
      case node.node_name
      when :metadata then node.metadata
      when :step then node._metadata
      else BLANK_HASH
      end
    rescue StandardError
      BLANK_HASH
    end

    def escape(label) = label.to_s.gsub('"', '#quot;')
  end
end

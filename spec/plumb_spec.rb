# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb do
  it 'has a version number' do
    expect(Plumb::VERSION).not_to be nil
  end

  describe '.resolve_base_types' do
    # A Composable::Node only re-labels the type it wraps, so it has the same base
    # types. It used to report none at all: its node_name is arbitrary, so it fell
    # through to the `else` branch, and a Node exposes no #children.
    {
      'Types::Email' => [::String],
      'Types::UUID::V4' => [::String],
      'Types::Boolean' => [::TrueClass, ::FalseClass]
    }.each do |const, expected|
      it "resolves through #{const}" do
        expect(Plumb.resolve_base_types(Object.const_get("Types::#{const.sub('Types::', '')}")))
          .to eq(expected)
      end
    end

    it 'resolves through a custom #as_node wrapper' do
      expect(Plumb.resolve_base_types(Types::Array[Types::Integer].as_node(:my_list)))
        .to eq([::Array])
    end

    it 'resolves through a factored union (:refined_union)' do
      expect(Plumb.resolve_base_types(Types::String[/a/] | Types::String[/b/])).to eq([::String])
    end

    # What the empty list was costing: every caller treats it as "unknown base,
    # allow", so build-time checks were silently skipped on any #as_node type.
    describe 'restores the build-time checks it was skipping' do
      it 'rejects a contradictory refinement of a named type' do
        expect { Types::Email[1..20] }.to raise_error(Plumb::TypeError)
        expect { Types::String[1..20] }.to raise_error(Plumb::TypeError) # control
      end

      it 'rejects a coercion the named type does not support' do
        expect { Types::Boolean.transform(:to_sym) }.to raise_error(Plumb::TypeError)
      end

      it 'lets a disjoint intersection collapse to Never' do
        expect(Types::Email & Types::Integer).to be_a(Plumb::NeverClass)
      end
    end
  end

  describe '.decorate' do
    it 'finds and replaces a step' do
      name = Types::String.where(size: 1..10)
      type = Types::Array[name].default([].freeze)
      type2 = Plumb.decorate(type) do |node|
        if node.is_a?(Plumb::ArrayClass)
          sub = node.children.first.transform(String) { |v| "Hello #{v}" }
          Types::Array[sub]
        else
          node
        end
      end

      expect(type.parse).to eq([])
      expect(type2.parse).to eq([])
      assert_result(type.resolve(%w[a b]), %w[a b], true)
      assert_result(type2.resolve(%w[a b]), ['Hello a', 'Hello b'], true)
    end

    it 'finds and replaces a callable wrapped in an opaque Function' do
      type = (Types::Integer >> ->(r) { r.valid(r.value * 2) }).default(1)
      type2 = Plumb.decorate(type) do |node|
        # #opaque? is what singles out a wrapped callable — a bare #is_a?(Function)
        # would also match every #transform / #build / coercion in the tree.
        if node.is_a?(Plumb::Function) && node.opaque?
          Plumb::Composable.wrap(->(r) { r.valid(r.value * 3) })
        else
          node
        end
      end
      expect(type.parse).to eq(1)
      expect(type.parse(2)).to eq(4)
      expect(type2.parse).to eq(1)
      expect(type2.parse(2)).to eq(6)
    end

    # The block used to be called on five node types only, so it never saw a
    # record's fields, a container's element type, or the inside of a
    # Metadata/Policy/#as_node wrapper. Traversal is Plumb::NodeMapper's now.
    describe 'reaches nested types' do
      def nodes_seen(type)
        seen = []
        Plumb.decorate(type) { |node| seen << node; node }
        seen
      end

      it 'visits a record\'s fields' do
        expect(nodes_seen(Types::Hash[a: Types::String])).to include(Types::String)
      end

      it 'visits a container\'s element and member types' do
        expect(nodes_seen(Types::Array[Types::String])).to include(Types::String)
        expect(nodes_seen(Types::Tuple[Types::String, Types::Integer]))
          .to include(Types::String, Types::Integer)
        expect(nodes_seen(Types::Hash[Types::Symbol, Types::Integer])).to include(Types::Integer)
        expect(nodes_seen(Types::Stream[Types::Integer])).to include(Types::Integer)
      end

      it 'visits inside transparent wrappers' do
        expect(nodes_seen(Types::String.metadata(x: 1))).to include(Types::String)
        expect(nodes_seen(Types::Email)).to include(Types::Email.type)
        # A policy wraps the node the policy BUILT (here a #check Constraint over
        # String), which is what gets visited.
        policy = Types::String.present
        expect(nodes_seen(policy)).to include(policy.children.first)
      end

      # Traversal stops at a Constraint's base: a Constraint carries an error
      # message and label it does not expose, so rebuilding one would silently drop
      # a custom `#check('...')` message.
      it 'does not descend into a Constraint base' do
        expect(nodes_seen(Types::Integer[1..10])).to eq([Types::Integer[1..10]])
      end

      it 'replaces a type nested two levels deep' do
        schema = Types::Hash[name: Types::String, tags: Types::Array[Types::String]]
        upcased = Plumb.decorate(schema) do |node|
          node.equal?(Types::String) ? Types::String.invoke(:upcase) : node
        end
        expect(upcased.parse({ name: 'jo', tags: %w[a b] })).to eq({ name: 'JO', tags: %w[A B] })
      end
    end

    # A pass in which nothing changed must return the ORIGINAL object, so callers
    # can distinguish "no-op" from "rebuilt identically" and a no-op allocates
    # nothing. Every node shape has to honour it uniformly.
    describe 'preserves identity when nothing changes' do
      linked_list = Types::Hash[value: Types::Integer]
      {
        'a record' => Types::Hash[a: Types::String, b: Types::Array[Types::Integer]],
        'a tuple' => Types::Tuple[Types::String, Types::Integer],
        'a hash map' => Types::Hash[Types::Symbol, Types::Integer],
        'a stream' => Types::Stream[Types::Integer],
        'metadata' => Types::String.metadata(x: 1),
        'an #as_node wrapper' => Types::Email,
        'a policy' => Types::String.present,
        'a union' => Types::String | Types::Integer,
        'a composition' => Types::String >> Types::String.transform(::Integer, &:to_i),
        'a negation' => Types::String.not,
        'a struct' => Types::Data[name: Types::String],
        'a recursive type' => linked_list,
        'a codec rewrite' => Plumb::Codec::Forms >> Types::Hash[age: Types::Integer]
      }.each do |label, type|
        it label do
          expect(Plumb.decorate(type) { |node| node }).to be(type)
        end
      end

      # Not forced, or it would recurse forever on a self-referential type.
      it 'does not force a Deferred' do
        forced = false
        deferred = Types::Any.defer { forced = true and Types::String }
        Plumb.decorate(deferred) { |node| node }
        expect(forced).to be(false)
      end
    end
  end
end

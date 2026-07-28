# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb::VisitorHandlers do
  # A visitor written against the pre-split AST: it knows :and and :or, because
  # that is what an Intersection and a Union used to report.
  class LegacyVisitor
    include Plumb::VisitorHandlers

    on(:and) { |node, _props| [:and, node.children.size] }
    on(:or) { |node, _props| [:or, node.children.size] }
    on(:constraint) { |_node, _props| [:constraint] }
  end

  # A visitor that distinguishes the two, as Plumb's own now do.
  class SplitAwareVisitor
    include Plumb::VisitorHandlers

    on(:and) { |_node, _props| [:and] }
    on(:intersection) { |_node, _props| [:intersection] }
    on(:or) { |_node, _props| [:or] }
    on(:union) { |_node, _props| [:union] }
    on(:constraint) { |_node, _props| [:constraint] }
  end

  let(:intersection) { Types::String.where(size: 1..3) }
  let(:union) { Types::String | Types::Integer }
  let(:composition) { Types::String >> Types::String.transform(::Integer, &:to_i) }
  let(:choice) { Types::Integer | Types::String.transform(::Integer, &:to_i) }

  it 'reports the split node names' do
    expect(intersection.node_name).to eq(:intersection)
    expect(union.node_name).to eq(:union)
    expect(composition.node_name).to eq(:and)
    expect(choice.node_name).to eq(:or)
  end

  describe 'backwards compatibility for visitors that predate the split' do
    it 'falls back from :intersection to the :and handler' do
      expect(LegacyVisitor.visit(intersection)).to eq([:and, 2])
    end

    it 'falls back from :union to the :or handler' do
      expect(LegacyVisitor.visit(union)).to eq([:or, 2])
    end

    it 'still routes an actual composition and choice to those handlers' do
      expect(LegacyVisitor.visit(composition)).to eq([:and, 2])
      expect(LegacyVisitor.visit(choice)).to eq([:or, 2])
    end
  end

  describe 'a visitor that defines the specific handler' do
    it 'is never routed through the fallback' do
      expect(SplitAwareVisitor.visit(intersection)).to eq([:intersection])
      expect(SplitAwareVisitor.visit(union)).to eq([:union])
      expect(SplitAwareVisitor.visit(composition)).to eq([:and])
      expect(SplitAwareVisitor.visit(choice)).to eq([:or])
    end
  end

  it 'still raises for a node it has no handler (or fallback) for' do
    visitor = Class.new { include Plumb::VisitorHandlers }
    expect { visitor.visit(Types::String) }.to raise_error(/No handler/)
  end
end

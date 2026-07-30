# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb::MermaidVisitor do
  subject(:visitor) { described_class }

  # Abstract flow steps: Any accepts/produces anything, so `>>` never rejects
  # the composition — letting us diagram the algebra with named boxes.
  def step(title) = Types::Any.metadata(title:)

  specify 'a single leaf renders one box' do
    expect(described_class.call(step('A'))).to eq(<<~MERMAID.chomp)
      flowchart LR
        n1["A"]
    MERMAID
  end

  specify '`>>` (And) renders a sequential arrow' do
    type = step('A') >> step('B')
    expect(described_class.call(type)).to eq(<<~MERMAID.chomp)
      flowchart LR
        n1["A"]
        n2["B"]
        n1 --> n2
    MERMAID
  end

  specify '`|` (Or) forks from a synthetic start node' do
    type = step('A') | step('B')
    expect(described_class.call(type)).to eq(<<~MERMAID.chomp)
      flowchart LR
        start(( ))
        n1["A"]
        n2["B"]
        start --> n1
        start --> n2
    MERMAID
  end

  specify 'a following step joins both branches of a preceding Or' do
    type = (step('D') | step('B')) >> step('A')
    expect(described_class.call(type)).to eq(<<~MERMAID.chomp)
      flowchart LR
        start(( ))
        n1["D"]
        n2["B"]
        n3["A"]
        start --> n1
        start --> n2
        n1 --> n3
        n2 --> n3
    MERMAID
  end

  specify 'the canonical composition (A >> B) | (C >> (D | B))' do
    a = step('A')
    b = step('B')
    c = step('C')
    d = step('D')
    type = (a >> b) | (c >> (d | b))
    expect(described_class.call(type)).to eq(<<~MERMAID.chomp)
      flowchart LR
        start(( ))
        n1["A"]
        n2["B"]
        n3["C"]
        n4["D"]
        n5["B"]
        start --> n1
        start --> n3
        n1 --> n2
        n3 --> n4
        n3 --> n5
    MERMAID
  end

  specify 'direction is configurable' do
    expect(described_class.call(step('A'), direction: 'TB')).to start_with('flowchart TB')
  end

  describe 'labels' do
    it 'prefers a metadata title, then :label, then #inspect' do
      expect(described_class.call(Types::Any.metadata(title: 'By title'))).to include('["By title"]')
      expect(described_class.call(Types::Any.metadata(label: 'By label'))).to include('["By label"]')
      expect(described_class.call(Types::Integer)).to include('["Types::Integer"]')
    end

    it 'escapes double quotes in labels' do
      expect(described_class.call(Types::Any.metadata(title: 'say "hi"'))).to include('["say #quot;hi#quot;"]')
    end
  end

  describe 'transparent wrappers' do
    it 'unwraps a Pipeline to its inner composition' do
      pipeline = (step('A') >> step('B')).pipeline
      expect(described_class.call(pipeline)).to eq(<<~MERMAID.chomp)
        flowchart LR
          n1["A"]
          n2["B"]
          n1 --> n2
      MERMAID
    end
  end

  describe 'Deferred' do
    it 'renders a recursive type as a single opaque box (no infinite recursion)' do
      type = Types::Hash[
        value: Types::Any,
        next: Types::Any.defer { type }
      ]
      # Just needs to terminate and produce a box for the deferred child.
      expect(described_class.call(type)).to start_with('flowchart LR')
    end
  end

  specify 'exposed via Composable#to_mermaid' do
    type = step('A') >> step('B')
    expect(type.to_mermaid).to eq(described_class.call(type))
  end
end

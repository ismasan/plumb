# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb::Result do
  describe 'factory methods' do
    specify '.valid builds a valid result' do
      r = described_class.valid(10)
      expect(r.valid?).to be(true)
      expect(r.invalid?).to be(false)
      expect(r.value).to eq(10)
      expect(r.errors).to be_nil
    end

    specify '.invalid builds an invalid result carrying value and errors' do
      r = described_class.invalid(10, errors: 'nope')
      expect(r.valid?).to be(false)
      expect(r.invalid?).to be(true)
      expect(r.value).to eq(10)
      expect(r.errors).to eq('nope')
    end

    specify '.wrap passes through an existing Result and wraps a raw value' do
      existing = described_class.valid(1)
      expect(described_class.wrap(existing)).to be(existing)

      wrapped = described_class.wrap(2)
      expect(wrapped).to be_a(described_class)
      expect(wrapped.value).to eq(2)
      expect(wrapped.valid?).to be(true)
    end
  end

  describe 'copying form (#valid / #invalid)' do
    specify '#valid returns a NEW valid result and leaves the receiver untouched' do
      original = described_class.invalid(1, errors: 'bad')
      copy = original.valid(2)

      expect(copy).not_to be(original)              # a distinct object
      expect(copy.valid?).to be(true)
      expect(copy.value).to eq(2)
      expect(copy.errors).to be_nil

      # receiver is unchanged
      expect(original.valid?).to be(false)
      expect(original.value).to eq(1)
      expect(original.errors).to eq('bad')
    end

    specify '#valid with no argument copies the current value' do
      original = described_class.valid(5)
      copy = original.valid
      expect(copy).not_to be(original)
      expect(copy.value).to eq(5)
    end

    specify '#invalid returns a NEW invalid result and leaves the receiver untouched' do
      original = described_class.valid(1)
      copy = original.invalid(errors: 'bad')

      expect(copy).not_to be(original)
      expect(copy.invalid?).to be(true)
      expect(copy.value).to eq(1)                   # defaults to current value
      expect(copy.errors).to eq('bad')

      expect(original.valid?).to be(true)           # receiver untouched
      expect(original.errors).to be_nil
    end
  end

  describe 'in-place form (#valid! / #invalid!)' do
    specify '#invalid! flips the SAME object to invalid, keeping the value' do
      result = described_class.valid(42)
      returned = result.invalid!(errors: 'boom')

      expect(returned).to be(result)                # same object
      expect(result.invalid?).to be(true)
      expect(result.value).to eq(42)               # value preserved by default
      expect(result.errors).to eq('boom')
    end

    specify '#invalid! can replace the value as well' do
      result = described_class.valid(1)
      result.invalid!(2, errors: 'boom')
      expect(result.value).to eq(2)
      expect(result.invalid?).to be(true)
    end

    specify '#valid! flips the SAME object back to valid and clears errors' do
      result = described_class.invalid(1, errors: 'bad')
      returned = result.valid!(2)

      expect(returned).to be(result)
      expect(result.valid?).to be(true)
      expect(result.value).to eq(2)
      expect(result.errors).to be_nil
    end

    specify '#valid! with no argument keeps the current value but clears errors' do
      result = described_class.invalid(7, errors: 'bad')
      result.valid!
      expect(result.valid?).to be(true)
      expect(result.value).to eq(7)
      expect(result.errors).to be_nil
    end

    specify 'round-trips valid <-> invalid on one object without allocating' do
      result = described_class.valid(1)
      expect(result.invalid!(errors: 'e1')).to be(result)
      expect(result.valid!(2)).to be(result)
      expect(result.invalid!(errors: 'e2')).to be(result)
      expect(result.value).to eq(2)
      expect(result.errors).to eq('e2')
    end
  end

  describe '#reset' do
    specify 'flips the SAME object to a fresh valid state carrying the new value' do
      result = described_class.invalid(1, errors: 'bad')
      returned = result.reset(9)

      expect(returned).to be(result)
      expect(result.valid?).to be(true)
      expect(result.value).to eq(9)
      expect(result.errors).to be_nil
    end
  end

  describe '#map' do
    specify 'a valid result invokes the callable with itself' do
      result = described_class.valid(3)
      seen = nil
      out = result.map(->(r) { seen = r; described_class.valid(r.value * 2) })
      expect(seen).to be(result)
      expect(out.value).to eq(6)
    end

    specify 'an invalid result short-circuits, returning itself without calling' do
      result = described_class.invalid(3, errors: 'bad')
      called = false
      out = result.map(->(_) { called = true; described_class.valid(0) })
      expect(called).to be(false)
      expect(out).to be(result)
    end
  end
end

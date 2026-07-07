# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Plumb::Types::Stream do
  it 'returns an Enumerator that validates each row' do
    over_tens = Types::Stream[Types::Integer[10..]]
    stream = over_tens.parse([10, 20, 3, 40])

    assert_result(stream.next, 10, true)
    assert_result(stream.next, 20, true)
    assert_result(stream.next, 3, false)
    assert_result(stream.next, 40, true)
  end

  specify '#metadata' do
    stream = Types::Stream[Integer]
    expect(stream.metadata).to eq({})
  end

  specify '#filtered' do
    over_tens = Types::Stream[Types::Integer[10..]]
    stream = over_tens.filtered.parse([10, 20, 3, 40])
    expect(stream.to_a).to eq [10, 20, 40]
  end

  # Regression: ArrayClass reuses its own result cursor as the per-element
  # scratch (resetting it for each element). A Stream element's Enumerator must
  # close over its own snapshotted source, NOT that shared cursor — otherwise
  # every nested stream would replay whatever the cursor last held.
  describe 'nested in an Array (reused element cursor)' do
    it 'binds each stream to its own source, even when consumed out of order' do
      type = Types::Array[Types::Stream[Types::Lax::Integer]]
      result = type.resolve([%w[1 2], %w[3 4], %w[5 6]])

      expect(result.valid?).to be(true)
      streams = result.value.to_a
      expect(streams.size).to eq(3)
      # Reverse (and hence deferred) consumption proves each Enumerator kept its
      # own input rather than the array's since-mutated cursor.
      expect(streams.reverse.map { |s| s.map(&:value) }).to eq([[5, 6], [3, 4], [1, 2]])
    end
  end

  private

  def assert_result(result, value, is_success, debug: false)
    debugger if debug
    expect(result.value).to eq value
    expect(result.valid?).to be(is_success)
  end
end

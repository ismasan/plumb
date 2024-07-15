# frozen_string_literal: true

require 'spec_helper'
require 'plumb'

RSpec.describe Plumb do
  before :all do
    Plumb.policy :default_if_nil, helper: true do |type, arg|
      type | (Plumb::Types::Nil >> Plumb::Types::Static[arg])
    end

    Plumb.policy :test_present, for_type: String do |type, *_args|
      type.check('must be present') { |v| !v.empty? }
    end

    Plumb.policy :test_present, for_type: Array do |type, *_args|
      type.check('must be present') { |v| !v.empty? }
    end
  end

  it 'registers a helper method' do
    type = Types::String.default_if_nil('default')
    assert_result(type.resolve('yes'), 'yes', true)
    assert_result(type.resolve(nil), 'default', true)
    assert_result(type.resolve(10), 10, false)
  end

  it 'registers per-type policies' do
    str = Types::String.policy(:test_present)
    arr = Types::Array.policy(:test_present)

    assert_result(str.resolve('yes'), 'yes', true)
    assert_result(str.resolve(''), '', false)

    assert_result(arr.resolve([1]), [1], true)
    assert_result(arr.resolve([]), [], false)

    expect { Types::Integer.policy(:test_present) }.to raise_error(Plumb::Policies::UnknownPolicyError)
  end

  it 'supports applying multiple policies' do
    type = Types::String.policy(default_if_nil: 'default', test_present: true)
    assert_result(type.resolve('yes'), 'yes', true)
    assert_result(type.resolve(nil), 'default', true)
    assert_result(type.resolve(''), '', false)
  end

  it 'supports policies that take block' do
    Plumb.policy :suffix, for_type: String do |type, _args, block|
      type.transform(String, &block)
    end

    type = Types::String.policy(:suffix) { |v| v + '!' }
    assert_result(type.resolve('yes'), 'yes!', true)
  end

  it 'fails if different unioned types' do
    expect do
      (Types::String | Types::Integer).policy(:test_present)
    end.to raise_error(Plumb::Policies::DifferingTypesError)
  end

  it 'raises if trying to re-define helper method' do
    expect do
      Plumb.policy :default_if_nil, helper: true do |_type, _arg|
        type
      end
    end.to raise_error(Plumb::Policies::MethodAlreadyDefinedError)
  end
end

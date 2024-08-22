# frozen_string_literal: true

require 'spec_helper'

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

    Plumb.policy :the_size, for_type: :size do |type, size|
      type.check("must be of size #{size}") { |v| size === v.size }
    end

    Plumb.policy :admin, helper: true do |type|
      type.metadata(admin: true)
    end
  end

  it 'works with #metadata' do
    type = Types::String.admin
    expect(type.metadata[:admin]).to be(true)
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

  it 'can register policies for given interfaces' do
    type = (Types::String | Types::Array).policy(the_size: 2)
    assert_result(type.resolve('ye'), 'ye', true)
    assert_result(type.resolve('yes'), 'yes', false)
    assert_result(type.resolve([1, 2]), [1, 2], true)
    assert_result(type.resolve([1, 2, 3]), [1, 2, 3], false)
  end

  it 'supports applying multiple policies' do
    type = Types::String.policy(default_if_nil: 'default', test_present: true)
    assert_result(type.resolve('yes'), 'yes', true)
    assert_result(type.resolve(nil), 'default', true)
    assert_result(type.resolve(''), '', false)
  end

  it 'supports policies that take block' do
    Plumb.policy :suffix, for_type: String do |type, &block|
      type.transform(String, &block)
    end

    type = Types::String.policy(:suffix) { |v| v + '!' }
    assert_result(type.resolve('yes'), 'yes!', true)
  end

  it "fails if it can't find compatible policy for all types" do
    expect do
      (Types::String | Types::Integer).policy(:test_present)
    end.to raise_error(Plumb::Policies::UnknownPolicyError)
  end

  it 'raises if trying to re-define helper method' do
    expect do
      Plumb.policy :default_if_nil, helper: true do |_type, _arg|
        type
      end
    end.to raise_error(Plumb::Policies::MethodAlreadyDefinedError)
  end

  it 'supports shared policies for all Objects' do
    type = (Types::String | Types::Integer).nullable
    assert_result(type.resolve('yes'), 'yes', true)
    assert_result(type.resolve(nil), nil, true)
    assert_result(type.resolve(110), 110, true)
  end

  context 'with a self-contained policy' do
    it 'works' do
      multiply_policy = Class.new do
        def self.for_type = :*
        def self.helper = true

        def self.call(type, factor = 1)
          type.invoke(:*, factor)
        end
      end

      Plumb.policy :multiply_by, multiply_policy
      assert_result(Types::Integer.multiply_by(2).resolve(2), 4, true)
      assert_result(Types::Integer.multiply_by.resolve(2), 2, true)
    end
  end
end

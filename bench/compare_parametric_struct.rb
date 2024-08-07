# frozen_string_literal: true

require 'bundler'
Bundler.setup(:benchmark)

require 'benchmark/ips'
require 'parametric/struct'
require 'plumb'

module ParametricStruct
  class User
    include Parametric::Struct

    schema do
      field(:name).type(:string).present
      field(:friends).type(:array).schema do
        field(:name).type(:string).present
        field(:age).type(:integer)
      end
    end
  end
end

module PlumbStruct
  include Plumb::Types

  class User < Data
    attribute :name, String.present
    attribute :friends, Array do
      attribute :name, String.present
      attribute :age, Integer
    end
  end
end

module DataBaseline
  Friend = Data.define(:name, :age)
  User = Data.define(:name, :friends) do
    def self.build(data)
      data = data.merge(friends: data[:friends].map { |friend| Friend.new(**friend) })
      new(**data)
    end
  end
end

data = {
  name: 'John',
  friends: [
    { name: 'Jane', age: 30 },
    { name: 'Joan', age: 38 }
  ]
}

Benchmark.ips do |x|
  # x.report('Ruby Data') do
  #   user = DataBaseline::User.build(data)
  #   user.name
  # end
  x.report('Parametric::Struct') do
    user = ParametricStruct::User.new(data)
    user.name
  end
  x.report('Plumb::Types::Data') do
    user = PlumbStruct::User.new(data)
    user.name
  end
  x.compare!
end

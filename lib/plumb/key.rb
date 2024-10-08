# frozen_string_literal: true

module Plumb
  class Key
    OPTIONAL_EXP = /(\w+)(\?)?$/

    def self.wrap(key)
      key.is_a?(Key) ? key : new(key)
    end

    attr_reader :to_sym, :node_name

    def initialize(key, optional: false)
      key_s = key.to_s
      match = OPTIONAL_EXP.match(key_s)
      @node_name = :key
      @key = match[1]
      @to_sym = @key.to_sym
      @optional = !match[2].nil? ? true : optional
      freeze
    end

    def to_s = @key

    def hash
      @key.hash
    end

    def eql?(other)
      other.hash == hash
    end

    def optional?
      @optional
    end

    def inspect
      "#{@key}#{'?' if @optional}"
    end
  end
end

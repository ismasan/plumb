# frozen_string_literal: true

module Plumb
  class Key
    # OPTIONAL_EXP = /(\w+)(\?)?$/
    OPTIONAL_EXP = /(?<word>[A-Za-z0-9_$]+)(?<qmark>\?)?/

    def self.wrap(key, symbolize: false)
      key.is_a?(Key) ? key : new(key, symbolize:)
    end

    attr_reader :to_key, :to_sym, :node_name

    def initialize(key, optional: false, symbolize: false)
      key_type = symbolize ? Symbol : key.class
      match = OPTIONAL_EXP.match(key.to_s)
      key = match[:word]
      @to_key = key_type == Symbol ? key.to_sym : key
      @to_sym = @to_key.to_sym
      @optional = !match[:qmark].nil? ? true : optional
      @node_name = :key
      freeze
    end

    def to_s = @to_key.to_s

    def hash
      @to_key.hash
    end

    def eql?(other)
      other.hash == hash
    end

    def optional?
      @optional
    end

    def inspect
      "#{@to_key}#{'?' if @optional}"
    end
  end
end

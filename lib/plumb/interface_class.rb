# frozen_string_literal: true

require 'plumb/composable'

module Plumb
  class InterfaceClass
    include Composable

    attr_reader :method_names

    def initialize(method_names = [])
      @method_names = method_names
      freeze
    end

    def ==(other)
      other.is_a?(self.class) && other.method_names == method_names
    end

    def of(*args)
      case args
      in Array => symbols if symbols.all? { |s| s.is_a?(::Symbol) }
        self.class.new(symbols)
      else
        raise ::ArgumentError, "unexpected value to Types::Interface#of #{args.inspect}"
      end
    end

    alias [] of

    # Merge two interfaces into a new one with the method names of both
    # @example
    #   i1 = Types::Interface[:foo]
    #   i2 = Types::Interface[:bar, :lol]
    #   i3 = i1 + i2 # expects objects with methods :foo, :bar, :lol
    #
    # @param other [InterfaceClass]
    # @return [InterfaceClass]
    def +(other)
      raise ArgumentError, "expected another Types::Interface, but got #{other.inspect}" unless other.is_a?(self.class)

      self.class.new((method_names + other.method_names).uniq)
    end

    # Produce a new Interface with the intersection of two interfaces
    # @example
    #   i1 = Types::Interface[:foo, :bar]
    #   i2 = Types::Interface[:bar, :lol]
    #   i3 = i1 + i2 # expects objects with methods :bar
    #
    # @param other [InterfaceClass]
    # @return [InterfaceClass]
    def &(other)
      raise ArgumentError, "expected another Types::Interface, but got #{other.inspect}" unless other.is_a?(self.class)

      self.class.new(method_names & other.method_names)
    end

    def call(result)
      obj = result.value
      missing_methods = @method_names.reject { |m| obj.respond_to?(m) }
      return result.invalid(errors: "Invalid #{self.name}. Missing methods: #{missing_methods.join(', ')}") if missing_methods.any?

      result
    end

    private def _inspect = "Interface[#{method_names.join(', ')}]"
  end
end

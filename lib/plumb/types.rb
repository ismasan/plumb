# frozen_string_literal: true

require 'bigdecimal'

module Plumb
  # Define core policies
  policy :options, helper: true, for_type: ::Array do |type, opts|
    type.check("must be included in #{opts.inspect}") do |v|
      v.all? { |val| opts.include?(val) }
    end
  end

  policy :options do |type, opts|
    type.check("must be included in #{opts.inspect}") do |v|
      opts.include?(v)
    end
  end

  policy :excluded_from, for_type: ::Array do |type, opts|
    type.check("must not be included in #{opts.inspect}") do |v|
      v.none? { |val| opts.include?(val) }
    end
  end

  policy :excluded_from do |type, opts|
    type.check("must not be included in #{opts.inspect}") do |v|
      !opts.include?(v)
    end
  end

  [Array, String, Hash, Set].each do |klass|
    policy :size, for_type: klass do |type, size|
      type.check("must be of size #{size}") { |v| size === v.size }
    end
  end

  policy :present, helper: true do |type, *_args|
    type.check('must be present') do |v|
      if v.respond_to?(:empty?)
        !v.empty?
      else
        !v.nil?
      end
    end
  end

  policy :nullable, helper: true do |type, *_args|
    Types::Nil | type
  end

  policy :respond_to do |type, method_names|
    type.check("must respond to #{method_names.inspect}") do |value|
      Array(method_names).all? { |m| value.respond_to?(m) }
    end
  end

  policy :default, helper: true do |type, value, block|
    val_type = if value == Undefined
                 # DefaultProc.call(block)
                 Step.new(->(result) { result.valid(block.call) }, 'default proc')
               else
                 Types::Static[value]
               end

    type | (Types::Undefined >> val_type)
  end

  module Types
    extend TypeRegistry

    Any = AnyClass.new
    Undefined = Any.value(Plumb::Undefined)
    String = Any[::String]
    Symbol = Any[::Symbol]
    Numeric = Any[::Numeric]
    Integer = Any[::Integer]
    Decimal = Any[BigDecimal]
    Static = StaticClass.new
    Value = ValueClass.new
    Nil = Any[::NilClass]
    True = Any[::TrueClass]
    False = Any[::FalseClass]
    Boolean = (True | False).as_node(:boolean)
    Array = ArrayClass.new
    Stream = StreamClass.new
    Tuple = TupleClass.new
    Hash = HashClass.new
    Interface = InterfaceClass.new
    Split = String.transform(::String) { |v| v.split(/\s*,\s*/) }

    module Lax
      NUMBER_EXPR = /^\d{1,3}(?:,\d{3})*(?:\.\d+)?$/

      String = Types::String \
        | Types::Decimal.transform(::String) { |v| v.to_s('F') } \
        | Types::Numeric.transform(::String, &:to_s)

      Symbol = Types::Symbol | Types::String.transform(::Symbol, &:to_sym)

      NumberString = Types::String.match(NUMBER_EXPR)
      CoercibleNumberString = NumberString.transform(::String) { |v| v.tr(',', '') }

      Numeric = Types::Numeric | CoercibleNumberString.transform(::Numeric, &:to_f)

      Decimal = Types::Decimal | \
                (Types::Numeric.transform(::String, &:to_s) | CoercibleNumberString) \
                .transform(::BigDecimal) { |v| BigDecimal(v) }

      Integer = Numeric.transform(::Integer, &:to_i)
    end

    module Forms
      True = Types::True \
        | (
          Types::String[/^true$/i] \
          | Types::String['1'] \
          | Types::Integer[1]
        ).transform(::TrueClass) { |_| true }

      False = Types::False \
        | (
          Types::String[/^false$/i] \
          | Types::String['0'] \
          | Types::Integer[0]
        ).transform(::FalseClass) { |_| false }

      Boolean = True | False

      Nil = Nil | (String[BLANK_STRING] >> nil)
    end
  end
end

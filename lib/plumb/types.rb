# frozen_string_literal: true

require 'bigdecimal'

module Plumb
  Rules.define :included_in, 'elements must be included in %<value>s', expects: ::Array do |result, opts|
    result.value.all? { |v| opts.include?(v) }
  end
  Rules.define :included_in, 'must be included in %<value>s' do |result, opts|
    opts.include? result.value
  end
  Rules.define :excluded_from, 'elements must not be included in %<value>s', expects: ::Array do |result, value|
    result.value.all? { |v| !value.include?(v) }
  end
  Rules.define :excluded_from, 'must not be included in %<value>s' do |result, value|
    !value.include?(result.value)
  end
  Rules.define :respond_to, 'must respond to %<value>s' do |result, value|
    Array(value).all? { |m| result.value.respond_to?(m) }
  end
  Rules.define :size, 'must be of size %<value>s', expects: :size do |result, value|
    value === result.value.size
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
    # TODO: type-speficic concept of blank, via Rules
    Blank = (
      Undefined \
      | Nil \
      | String.value(BLANK_STRING) \
      | Hash.value(BLANK_HASH) \
      | Array.value(BLANK_ARRAY)
    )

    Present = Blank.invalid(errors: 'must be present')
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

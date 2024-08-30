# frozen_string_literal: true

require 'bigdecimal'
require 'uri'

module Plumb
  # Define core policies
  # Allowed options for an array type.
  # It validates that each element is in the options array.
  # Usage:
  #   type = Types::Array.options(['a', 'b'])
  policy :options, helper: true, for_type: ::Array do |type, opts|
    type.check("must be included in #{opts.inspect}") do |v|
      v.all? { |val| opts.include?(val) }
    end
  end

  # Generic options policy for all other types.
  # Usage:
  #   type = Types::String.options(['a', 'b'])
  policy :options do |type, opts|
    type.check("must be included in #{opts.inspect}") do |v|
      opts.include?(v)
    end
  end

  # Validate that array elements are NOT in the options array.
  # Usage:
  #   type = Types::Array.policy(excluded_from: ['a', 'b'])
  policy :excluded_from, for_type: ::Array do |type, opts|
    type.check("must not be included in #{opts.inspect}") do |v|
      v.none? { |val| opts.include?(val) }
    end
  end

  # Usage:
  #   type = Types::String.policy(excluded_from: ['a', 'b'])
  policy :excluded_from do |type, opts|
    type.check("must not be included in #{opts.inspect}") do |v|
      !opts.include?(v)
    end
  end

  # Validate #size against a number or any object that responds to #===.
  # This works with any type that repsonds to #size.
  # Usage:
  #   type = Types::String.policy(size: 10)
  #   type = Types::Integer.policy(size: 1..10)
  #   type = Types::Array.policy(size: 1..)
  #   type = Types::Any[Set].policy(size: 1..)
  policy :size, for_type: :size do |type, size|
    type.check("must be of size #{size}") { |v| size === v.size }
  end

  # Validate that an object is not #empty? nor #nil?
  # Usage:
  #   Types::String.present
  #   Types::Array.present
  policy :present, helper: true do |type, *_args|
    type.check('must be present') do |v|
      if v.respond_to?(:empty?)
        !v.empty?
      else
        !v.nil?
      end
    end
  end

  # Allow nil values for a type.
  # Usage:
  #   nullable_int = Types::Integer.nullable
  #   nullable_int.parse(nil) # => nil
  #   nullable_int.parse(10)  # => 10
  #   nullable_int.parse('nope') # => error: not an Integer
  policy :nullable, helper: true do |type, *_args|
    Types::Nil | type
  end

  # Validate that a value responds to a method
  # Usage:
  #  type = Types::Any.policy(respond_to: :upcase)
  #  type = Types::Any.policy(respond_to: [:upcase, :strip])
  policy :respond_to do |type, method_names|
    type.check("must respond to #{method_names.inspect}") do |value|
      Array(method_names).all? { |m| value.respond_to?(m) }
    end
  end

  # Return a default value if the input value is Undefined (ie key not present in a Hash).
  # Usage:
  #   type = Types::String.default('default')
  #   type.parse(Undefined) # => 'default'
  #   type.parse('yes')     # => 'yes'
  #
  # Works with a block too:
  #   date = Type::Any[Date].default { Date.today }
  #
  policy :default, helper: true do |type, value = Undefined, &block|
    val_type = if value == Undefined
                 Step.new(->(result) { result.valid(block.call) }, 'default proc')
               else
                 Types::Static[value]
               end

    (Types::Undefined >> val_type) | type
  end

  # Split a string into an array. Default separator is /\s*,\s*/
  # Usage:
  #   type = Types::String.split
  #   type.parse('a,b,c') # => ['a', 'b', 'c']
  #
  # Custom separator:
  #   type = Types::String.split(';')
  module SplitPolicy
    DEFAULT_SEPARATOR = /\s*,\s*/

    def self.call(type, separator = DEFAULT_SEPARATOR)
      type.invoke(:split, separator) >> Types::Array[String]
    end

    def self.for_type = ::String
    def self.helper = false
  end

  policy :split, SplitPolicy

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
    Email = String[URI::MailTo::EMAIL_REGEXP]

    module UUID
      V4 = String[/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i]
    end

    class Data
      extend Composable
      include Plumb::Attributes
    end

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

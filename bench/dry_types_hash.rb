# frozen_string_literal: true

require 'dry/types'
require 'date'
require 'money'
require 'monetize'

# Dry::Types port of PlumbHash::Record (see bench/plumb_hash.rb) — the same
# nested record with the same coercions/defaults/nullability, built with
# dry-types hash schemas so the comparison is apples-to-apples.
module DryTypesHash
  module T
    include Dry.Types()
  end

  BLANK_ARRAY = [].freeze
  BLANK_STRING = ''

  # Custom Money type: pass a Money through, else parse via Monetize (mirrors
  # PlumbHash::Money). STUB_MONEY swaps it for an identity passthrough (see
  # plumb_hash.rb) so the benchmark can measure the schema WITHOUT the shared
  # money-parsing cost that both libraries otherwise pay.
  Money = if ENV['STUB_MONEY']
            T::Any
          else
            T.Constructor(::Money) do |value|
              value.is_a?(::Money) ? value : Monetize.parse!(value.to_s.gsub(',', ''))
            end
          end

  # Blank string -> nil, otherwise coerce to a Date (mirrors Forms::Nil | Forms::Date).
  BlankStringOrDate = T::Params::Date.optional

  PresentString = T::Strict::String.constrained(min_size: 1)
  Integer0 = T::Coercible::Integer.default(0)
  NullableInteger = T::Coercible::Integer.optional
  NullableMoney = Money.optional
  DefaultString = T::String.default(BLANK_STRING)

  Term = T::Hash.schema(
    name: DefaultString,
    url: DefaultString,
    terms_text: DefaultString,
    start_date?: BlankStringOrDate,
    end_date?: BlankStringOrDate
  )

  TvComponent = T::Hash.schema(
    slug: T::String,
    name: PresentString,
    search_tags: T::Array.of(T::String).default(BLANK_ARRAY),
    description: DefaultString,
    channels: Integer0,
    discount_price: Money.default(::Money.zero.freeze)
  )

  BroadbandComponent = T::Hash.schema(
    name: T::String,
    technology: T::String,
    is_mobile: T::Strict::Bool.default(false),
    description: T::String,
    technology_tags: T::Array.of(T::String).default(BLANK_ARRAY),
    download_speed_measurement: DefaultString,
    download_speed: T::Coercible::Float.default(0.0),
    upload_speed_measurement: DefaultString,
    upload_speed: T::Coercible::Float.default(0.0),
    download_usage_limit: NullableInteger,
    discount_price: NullableMoney,
    discount_period: NullableInteger,
    speed_description: DefaultString,
    ongoing_price: NullableMoney,
    contract_length: NullableInteger,
    upfront_cost: NullableMoney,
    commission: NullableMoney
  )

  PhoneComponent = T::Hash.schema(
    name: T::String,
    description: T::String,
    discount_price: NullableMoney,
    discount_period: NullableInteger,
    ongoing_price: NullableMoney,
    contract_length: NullableInteger,
    upfront_cost: NullableMoney,
    commission: NullableMoney,
    call_package_type: T::Array.of(T::String).default(BLANK_ARRAY)
  )

  Discount = T::Hash.schema(
    period: T::Coercible::Integer,
    price: NullableMoney
  )

  Record = T::Hash.schema(
    supplier_name: PresentString,
    start_date: BlankStringOrDate,
    end_date: BlankStringOrDate,
    countdown_date: BlankStringOrDate,
    name: PresentString,
    upfront_cost_description: DefaultString,
    tv_channels_count: Integer0,
    # Plumb's `.where(size: 1..).default([])` (default bypasses the size check)
    # has no direct dry equivalent — dry rejects a default that violates the
    # constraint. The data always provides `terms`, so keep the size check.
    terms: T::Array.of(Term).constrained(min_size: 1),
    tv_included: T::Strict::Bool,
    additional_info: T::String,
    product_type: T::String.optional,
    annual_price_increase_applies: T::Strict::Bool.default(false),
    annual_price_increase_description: DefaultString,
    broadband_components: T::Array.of(BroadbandComponent),
    tv_components: T::Array.of(TvComponent).default(BLANK_ARRAY),
    call_package_types: T::Array.of(T::String).default(BLANK_ARRAY),
    phone_components: T::Array.of(PhoneComponent).default(BLANK_ARRAY),
    payment_methods: T::Array.of(T::String).default(BLANK_ARRAY),
    discounts: T::Array.of(Discount),
    ongoing_price: NullableMoney,
    contract_length: NullableInteger,
    upfront_cost: NullableMoney,
    year_1_price: NullableMoney,
    savings: NullableMoney,
    commission: NullableMoney,
    max_broadband_download_speed: Integer0
  )
end

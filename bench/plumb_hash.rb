# frozen_string_literal: true

require 'plumb'
require 'date'
require 'money'
require 'monetize'

module PlumbHash
  include Plumb::Types

  BLANK_ARRAY = [].freeze
  BLANK_STRING = ''
  MONEY_EXP = /(\W{1}|\w{3})?[\d+,.]/

  PARSE_MONEY = proc do |result|
    value = Monetize.parse!(result.value.to_s.gsub(',', ''))
    result.valid(value)
  end

  BlankStringOrDate = Forms::Nil | Forms::Date

  Money = Any[::Money] \
    | (String.present >> PARSE_MONEY) \
    | (Numeric >> PARSE_MONEY)

  Term = Hash[
    name: String.default(BLANK_STRING),
    url: String.default(BLANK_STRING),
    terms_text: String.default(BLANK_STRING),
    start_date?: BlankStringOrDate.nullable,
    end_date?: BlankStringOrDate.nullable
  ]

  TvComponent = Hash[
    slug: String,
    name: String.present,
    search_tags: Array[String].default(BLANK_ARRAY),
    description: String.default(BLANK_STRING),
    channels: Integer.default(0),
    discount_price: Money.default(::Money.zero.freeze)
  ]

  Record = Hash[
    supplier_name: String.present,
    start_date: BlankStringOrDate.nullable.metadata(admin_ui: true),
    end_date: BlankStringOrDate.nullable.metadata(admin_ui: true),
    countdown_date: BlankStringOrDate.nullable,
    name: String.present,
    upfront_cost_description: String.default(BLANK_STRING),
    tv_channels_count: Integer.default(0),
    terms: Array[Term].policy(size: 1..).default(BLANK_ARRAY),
    tv_included: Boolean,
    additional_info: String,
    product_type: String.nullable,
    annual_price_increase_applies: Boolean.default(false),
    annual_price_increase_description: String.default(BLANK_STRING),
    broadband_components: Array[
      name: String,
      technology: String,
      is_mobile: Boolean.default(false),
      desciption: String,
      technology_tags: Array[String].default(BLANK_ARRAY),
      download_speed_measurement: String.default(BLANK_STRING),
      download_speed: Numeric.default(0),
      upload_speed_measurement: String.default(BLANK_STRING),
      upload_speed: Numeric.default(0),
      download_usage_limit: Integer.nullable,
      discount_price: Money.nullable,
      discount_period: Integer.nullable,
      speed_description: String.default(BLANK_STRING),
      ongoing_price: Money.nullable,
      contract_length: Integer.nullable,
      upfront_cost: Money.nullable,
      commission: Money.nullable
    ],
    tv_components: Array[TvComponent].default(BLANK_ARRAY),
    call_package_types: Array[String].default(BLANK_ARRAY).metadata(example: ['Everything']),
    phone_components: Array[
      name: String,
      description: String,
      discount_price: Money.nullable,
      discount_period: Integer.nullable,
      ongoing_price: Money.nullable,
      contract_length: Integer.nullable,
      upfront_cost: Money.nullable,
      commission: Money.nullable,
      call_package_type: Array[String].default(BLANK_ARRAY)
    ].default(BLANK_ARRAY),
    payment_methods: Array[String].default(BLANK_ARRAY),
    discounts: Array[period: Integer, price: Money.nullable],
    ongoing_price: Money.nullable.metadata(admin_ui: true),
    contract_length: Integer.nullable,
    upfront_cost: Money.nullable,
    year_1_price: Money.nullable.metadata(admin_ui: true),
    savings: Money.nullable.metadata(admin_ui: true),
    commission: Money.nullable,
    max_broadband_download_speed: Integer.default(0)
  ]
end

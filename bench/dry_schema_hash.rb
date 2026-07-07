# frozen_string_literal: true

require 'dry/schema'
require 'date'
require 'money'
require 'monetize'

# Dry::Schema port of PlumbHash::Record (see bench/plumb_hash.rb), for an
# apples-to-apples comparison: like Plumb (and unlike raw Dry::Types), a
# Dry::Schema returns a Result carrying ALL errors and never raises — and it
# additionally resolves human-readable messages via `result.errors.to_h`.
#
# Params schema so string dates coerce to Date and the native ints/bools pass
# through. Plumb `.default(x)` fields are provided by the sample data, so they
# map to `required`. Numeric maps to :integer (the sample values are integers).
module DrySchemaHash
  module T
    include Dry.Types()
  end

  # Same coercion as PlumbHash::Money — a single constructor, not a union.
  # STUB_MONEY swaps it for an identity passthrough (see plumb_hash.rb).
  MoneyType = if ENV['STUB_MONEY']
                T::Any
              else
                T.Constructor(::Money) do |v|
                  v.is_a?(::Money) ? v : Monetize.parse!(v.to_s.gsub(',', ''))
                end
              end

  Record = Dry::Schema.Params do
    required(:supplier_name).filled(:string)
    required(:start_date).maybe(:date)
    required(:end_date).maybe(:date)
    required(:countdown_date).maybe(:date)
    required(:name).filled(:string)
    required(:upfront_cost_description).value(:string)
    required(:tv_channels_count).value(:integer)
    required(:terms).array(:hash) do
      required(:name).value(:string)
      required(:url).value(:string)
      required(:terms_text).value(:string)
      optional(:start_date).maybe(:date)
      optional(:end_date).maybe(:date)
    end
    required(:tv_included).value(:bool)
    required(:additional_info).value(:string)
    required(:product_type).maybe(:string)
    required(:annual_price_increase_applies).value(:bool)
    required(:annual_price_increase_description).value(:string)
    required(:broadband_components).array(:hash) do
      required(:name).value(:string)
      required(:technology).value(:string)
      required(:is_mobile).value(:bool)
      required(:description).value(:string)
      required(:technology_tags).array(:string)
      required(:download_speed_measurement).value(:string)
      required(:download_speed).value(:integer)
      required(:upload_speed_measurement).value(:string)
      required(:upload_speed).value(:integer)
      required(:download_usage_limit).maybe(:integer)
      required(:discount_price).maybe(MoneyType)
      required(:discount_period).maybe(:integer)
      required(:speed_description).value(:string)
      required(:ongoing_price).maybe(MoneyType)
      required(:contract_length).maybe(:integer)
      required(:upfront_cost).maybe(MoneyType)
      required(:commission).maybe(MoneyType)
    end
    required(:tv_components).array(:hash) do
      required(:slug).value(:string)
      required(:name).filled(:string)
      required(:search_tags).array(:string)
      required(:description).value(:string)
      required(:channels).value(:integer)
      required(:discount_price).value(MoneyType)
    end
    required(:call_package_types).array(:string)
    required(:phone_components).array(:hash) do
      required(:name).value(:string)
      required(:description).value(:string)
      required(:discount_price).maybe(MoneyType)
      required(:discount_period).maybe(:integer)
      required(:ongoing_price).maybe(MoneyType)
      required(:contract_length).maybe(:integer)
      required(:upfront_cost).maybe(MoneyType)
      required(:commission).maybe(MoneyType)
      optional(:call_package_type).array(:string)
    end
    required(:payment_methods).array(:string)
    required(:discounts).array(:hash) do
      required(:period).value(:integer)
      required(:price).maybe(MoneyType)
    end
    required(:ongoing_price).maybe(MoneyType)
    required(:contract_length).maybe(:integer)
    required(:upfront_cost).maybe(MoneyType)
    required(:year_1_price).maybe(MoneyType)
    required(:savings).maybe(MoneyType)
    required(:commission).maybe(MoneyType)
    required(:max_broadband_download_speed).value(:integer)
  end
end

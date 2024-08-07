# frozen_string_literal: true

require 'bundler'
Bundler.setup(:benchmark)

require 'benchmark/ips'
require 'money'
Money.rounding_mode = BigDecimal::ROUND_HALF_EVEN
Money.default_currency = 'GBP'
require_relative './parametric_schema'
require_relative './plumb_hash'

data = {
  supplier_name: 'Vodafone',
  start_date: '2020-01-01',
  end_date: '2021-01-11',
  countdown_date: '2021-01-11',
  name: 'Vodafone TV',
  upfront_cost_description: 'Upfront cost description',
  tv_channels_count: 100,
  terms: [
    { name: 'Foo', url: 'http://foo.com', terms_text: 'Foo terms', start_date: '2020-01-01', end_date: '2021-01-01' },
    { name: 'Foo2', url: 'http://foo2.com', terms_text: 'Foo terms', start_date: '2020-01-01', end_date: '2021-01-01' }
  ],
  tv_included: true,
  additional_info: 'Additional info',
  product_type: 'TV',
  annual_price_increase_applies: true,
  annual_price_increase_description: 'Annual price increase description',
  broadband_components: [
    {
      name: 'Broadband 1',
      technology: 'FTTP',
      technology_tags: ['FTTP'],
      is_mobile: false,
      description: 'Broadband 1 description',
      download_speed_measurement: 'Mbps',
      download_speed: 100,
      upload_speed_measurement: 'Mbps',
      upload_speed: 100,
      download_usage_limit: 1000,
      discount_price: 100,
      discount_period: 12,
      speed_description: 'Speed description',
      ongoing_price: 100,
      contract_length: 12,
      upfront_cost: 100,
      commission: 100
    }
  ],
  tv_components: [
    {
      slug: 'vodafone-tv',
      name: 'Vodafone TV',
      search_tags: %w[Vodafone TV],
      description: 'Vodafone TV description',
      channels: 100,
      discount_price: 100
    }
  ],
  call_package_types: ['Everything'],
  phone_components: [
    {
      name: 'Phone 1',
      description: 'Phone 1 description',
      discount_price: 100,
      disount_period: 12,
      ongoing_price: 100,
      contract_length: 12,
      upfront_cost: 100,
      commission: 100,
      call_package_types: ['Everything']
    }
  ],
  payment_methods: ['Credit Card', 'Paypal'],
  discounts: [
    { period: 12, price: 100 }
  ],
  ongoing_price: 100,
  contract_length: 12,
  upfront_cost: 100,
  year_1_price: 100,
  savings: 100,
  commission: 100,
  max_broadband_download_speed: 100
}

# p V1Schemas::RECORD.resolve(data).errors
# p V2Schemas::Record.resolve(data)
# result = Parametric::V2::Result.wrap(data)

# p result
# p V2Schema.call(result)
Benchmark.ips do |x|
  x.report('Parametric::Schema') do
    ParametricSchema::RECORD.resolve(data)
  end
  x.report('Plumb') do
    PlumbHash::Record.resolve(data)
  end
  x.compare!
end

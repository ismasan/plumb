# frozen_string_literal: true

# Profiles JSON Schema GENERATION (the JSONSchemaVisitor traversal) for a
# realistic, deeply nested REST API payload — an e-commerce "Order" resource
# with a customer, addresses, line items, enums, coercing composite types
# (a Forms-coerced date and boolean, Lax::Integer/Decimal/String) and unions.
#
# Compositions are reduced at build time (union absorption/factoring,
# refinement/where collapse), so the type GRAPH the visitor walks is smaller and
# the emitted schema is flatter (folded anyOf, factored enums). This measures the
# resulting generation cost — run it before and after a change to compare.
#
# Public API only. NB: there is no Types::Lax::Date; a coercing date/boolean is
# `real type | the matching Codec::Forms encoder` (see FormsDate / FormsBoolean).

require 'plumb'
require 'json'
require 'date'

ITERS = 20_000

module T
  include Plumb::Types
end

EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
SKU   = /\A[A-Z0-9\-]+\z/
REF   = /\A[A-Z0-9]{8,}\z/

# Coercing scalars: "accept the parsed Ruby value, or decode the stringly form" —
# the same shape as `Types::Lax::*`, built from the Forms codec's encoders. Both
# branches matter here: a coercing field is exactly what makes the visitor fold a
# union into one field spec.
FORMS = Plumb::Codec::Forms
FormsDate = T::Date | FORMS::DateEncoder
FormsBoolean = T::Boolean | FORMS::TrueEncoder | FORMS::FalseEncoder

# Enums built as unions of literal String constraints — factoring pulls the shared
# `String` gate out into one `anyOf`.
Currency = T::String['USD'] | T::String['EUR'] | T::String['GBP']
Status   = T::String['pending'] | T::String['paid'] | T::String['shipped'] | T::String['cancelled']

Address = T::Hash[
  street: T::String.where(size: 1..200),
  city: T::String,
  postal_code: T::Lax::String,
  country_code: T::String.where(size: 2)
]

LineItem = T::Hash[
  sku: T::String[SKU],
  description: (T::String | T::Nil),
  quantity: T::Lax::Integer,
  unit_price: T::Lax::Decimal,
  currency: Currency,
  tags: T::Array[T::String]
]

Customer = T::Hash[
  id: T::Integer,
  name: T::String.where(size: 1..100),
  email: T::String[EMAIL],
  phone: (T::String | T::Nil),
  verified: FormsBoolean,
  loyalty_points: (T::Integer | T::Numeric), # value-preserving union -> absorbs to Numeric
  address: Address,
  billing_address: Address
]

ORDER = T::Hash[
  id: T::Integer,
  reference: T::String[REF],
  status: Status,
  currency: Currency,
  created_at: FormsDate,
  updated_at: FormsDate,
  shipped_at: (FormsDate | T::Nil),
  subtotal: T::Lax::Decimal,
  tax: T::Lax::Decimal,
  total: T::Lax::Decimal,
  customer: Customer,
  items: T::Array[LineItem],
  metadata: T::Hash[T::String, T::Lax::String],
  notes: (T::String | T::Nil)
].freeze

def measure_generation(type, iters = ITERS)
  type.to_json_schema(root: true) # warm up
  GC.start
  a0 = GC.stat(:total_allocated_objects)
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iters.times { type.to_json_schema(root: true) }
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  a1 = GC.stat(:total_allocated_objects)
  [(t1 - t0) * 1e9 / iters, (a1 - a0).to_f / iters]
end

schema = ORDER.to_json_schema(root: true)
json_bytes = JSON.generate(schema).bytesize
us_per, allocs_per = measure_generation(ORDER)

puts "== plumb JSON Schema generation — Ruby #{RUBY_VERSION} =="
puts format('%-26s %s', 'payload', 'REST "Order" (nested: customer, 2 addresses, line items, enums, coercers)')
puts format('%-26s %.1f', 'us / generation', us_per / 1000.0)
puts format('%-26s %.0f', 'allocs / generation', allocs_per)
puts format('%-26s %d bytes', 'emitted schema size', json_bytes)
puts format('%-26s %d', 'top-level properties', (schema['properties'] || {}).size)

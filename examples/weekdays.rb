# frozen_string_literal: true

require 'bundler'
Bundler.setup(:examples)
require 'plumb'

#   bundle exec ruby examples/weekdays.rb
#
# Data types to represent and parse an array of days of the week.
# Input data can be an array of day names or numbers, ex.
#   ['monday', 'tuesday', 'wednesday']
#   [1, 2, 3]
#
# Or mixed:
#   [1, 'Tuesday', 3]
#
# Validate that there aren't repeated days, ex. [1, 2, 4, 2]
# The output is an array of day numbers, ex. [1, 2, 3]
module Types
  include Plumb::Types

  DAYS = {
    'monday' => 1,
    'tuesday' => 2,
    'wednesday' => 3,
    'thursday' => 4,
    'friday' => 5,
    'saturday' => 6,
    'sunday' => 7
  }.freeze

  # Validate that a string is a valid day name, down-case it.
  DayName = String
            .transform(::String, &:downcase)
            .options(DAYS.keys)

  # Turn a day name into its number, or validate that a number is a valid day number.
  DayNameOrNumber = DayName.transform(::Integer) { |v| DAYS[v] } | Integer.options(DAYS.values)

  # An Array for days of the week, with no repeated days.
  # Ex. [1, 2, 3, 4, 5, 6, 7], [1, 2, 4], ['monday', 'tuesday', 'wednesday', 7]
  # Turn day names into numbers, and sort the array.
  Week = Array[DayNameOrNumber]
         .policy(size: 1..7)
         .check('repeated days') { |days| days.uniq.size == days.size }
         .transform(::Array, &:sort)
end

p Types::DayNameOrNumber.parse('monday')            # => 1
p Types::DayNameOrNumber.parse(3)                   # => 3
p Types::DayName.parse('TueSday')                   # => "tuesday
p Types::Week.parse([3, 2, 1, 4, 5, 6, 7])          # => [1, 2, 3, 4, 5, 6, 7]
p Types::Week.parse([1, 'Tuesday', 3, 4, 5, 'saturday', 7]) # => [1, 2, 3, 4, 5, 6, 7]

# p Types::Week[[1, 1, 3, 4, 5, 6, 7]] # raises Plumb::ParseError: repeated days
#
# Or use these types as part of other composite types, ex.
#
#   PartTimeJob = Types::Hash[
#     role: Types::String.present,
#     days_of_the_week: Types::Week
#   ]
#
#   result = PartTimeJob.resolve(role: 'Ruby dev', days_of_the_week: %w[Tuesday Wednesday])
#   result.valid? # true
#   result.value # { role: 'Ruby dev', days_of_the_week: [2, 3] }

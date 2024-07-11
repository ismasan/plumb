# frozen_string_literal: true

require 'bundler/setup'
require 'plumb'
require 'csv'

# Defines types and pipelines for opening and working with CSV streams.
# Run with `bundle exec ruby examples/csv_stream.rb`
module Types
  include Plumb::Types

  # Open a File
  # ex. file = FileStep.parse('./files/data.csv') # => File
  OpenFile = String
             .check('no file for that path') { |s| ::File.exist?(s) }
             .build(::File)

  # Turn a File into a CSV stream
  # ex. csv_enum = FileToCSV.parse(file) #=> Enumerator
  FileToCSV = Types::Any[::File]
              .build(CSV)
              .transform(::Enumerator, &:each)

  # Turn a string file path into a CSV stream
  # ex. csv_enum = StrinToCSV.parse('./files/data.csv') #=> Enumerator
  StringToCSV = OpenFile >> FileToCSV
end

#################################################
# Program 1: stream a CSV list of programmers and filter them by age.
#################################################

# This is a CSV row for a programmer over the age of 18.
AdultProgrammer = Types::Tuple[
  # Name
  String,
  # Age. Coerce to Integer and constrain to 18 or older.
  Types::Lax::Integer[18..],
  # Programming language
  String
]

# An Array of AdultProgrammer.
AdultProgrammerArray = Types::Array[AdultProgrammer]

# A pipeline to open a file, parse CSV and stream rows of AdultProgrammer.
AdultProgrammerStream = Types::StringToCSV >> AdultProgrammerArray.stream

# List adult programmers from file.
puts 'Adult programmers:'
AdultProgrammerStream.parse('./examples/programmers.csv').each do |row|
  puts row.value.inspect if row.valid?
end

# The filtering can also be achieved with Stream#filter
#  AdultProgrammerStream = Types::StringToCSV >> AdultProgrammerArray.stream.filtered

#################################################
# Program 2: list Ruby programmers from a CSV file.
#################################################

RubyProgrammer = Types::Tuple[
  String, # Name
  Types::Lax::Integer, # Age
  Types::String[/^ruby$/i] # Programming language
]

# A pipeline to open a file, parse CSV and stream rows of AdultProgrammer.
# This time we use Types::Stream directly.
RubyProgrammerStream = Types::StringToCSV >> Types::Stream[RubyProgrammer].filtered

# List Ruby programmers from file.
puts
puts '----------------------------------------'
puts 'Ruby programmers:'
RubyProgrammerStream.parse('./examples/programmers.csv').each do |person|
  puts person.inspect
end

# We can filter Ruby OR Elixir programmers with a union type.
# Lang = Types::String['ruby'] | Types::String['elixir']
# Or with allowe values:
# Lang = Types::String.options(%w[ruby elixir])

#################################################
# Program 3: negate the stream above to list non-Ruby programmers.
#################################################

# See the `.not` which negates the type.
NonRubyProgrammerStream = Types::StringToCSV >> Types::Stream[RubyProgrammer.not].filtered

puts
puts '----------------------------------------'
puts 'NON Ruby programmers:'
NonRubyProgrammerStream.parse('./examples/programmers.csv').each do |person|
  puts person.inspect
end

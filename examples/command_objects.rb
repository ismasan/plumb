# frozen_string_literal: true

require 'bundler'
Bundler.setup(:examples)
require 'plumb'
require 'json'
require 'fileutils'
require 'money'

Money.default_currency = Money::Currency.new('GBP')
Money.locale_backend = nil
Money.rounding_mode = BigDecimal::ROUND_HALF_EVEN

# Different approaches to the Command Object pattern using composable Plumb types.
module Types
  include Plumb::Types

  # Note that within this `Types` module, when we say String, Integer etc, we mean Types::String, Types::Integer etc.
  # Use ::String to refer to Ruby's String class.
  #
  ###############################################################
  # Define core types in the domain
  # The task is to process, validate and store mortgage applications.
  ###############################################################

  # Turn integers into Money objects (requires the money gem)
  Amount = Integer.build(Money)

  # A naive email check
  Email = String[/\w+@\w+\.\w+/]

  # A valid customer type
  Customer = Hash[
    name: String.present,
    age?: Integer[18..],
    email: Email
  ]

  # A step to validate a Mortgage application payload
  # including valid customer, mortgage type and minimum property value.
  MortgagePayload = Hash[
    customer: Customer,
    type: String.options(%w[first-time switcher remortgage]).default('first-time'),
    property_value: Integer[100_000..] >> Amount,
    mortgage_amount: Integer[50_000..] >> Amount,
    term: Integer[5..30],
  ]

  # A domain validation step: the mortgage amount must be less than the property value.
  # This is just a Proc that implements the `#call(Result::Valid) => Result::Valid | Result::Invalid` interface.
  # # Note that this can be anything that supports that interface, like a lambda, a method, a class etc.
  ValidateMortgageAmount = proc do |result|
    if result.value[:mortgage_amount] > result.value[:property_value]
      result.invalid(errors: { mortgage_amount: 'Cannot exceed property value' })
    else
      result
    end
  end

  # A step to create a mortgage application
  # This could be backed by a database (ex. ActiveRecord), a service (ex. HTTP API), etc.
  # For this example I just save JSON files to disk.
  class MortgageApplicationsStore
    def self.call(result) = new.call(result)

    def initialize(dir = './examples/data/applications')
      @dir = dir
      FileUtils.mkdir_p(dir)
    end

    # The Plumb::Step interface to make these objects composable.
    # @param result [Plumb::Result::Valid]
    # @return [Plumb::Result::Valid, Plumb::Result::Invalid]
    def call(result)
      if save(result.value)
        result
      else
        result.invalid(errors: 'Could not save application')
      end
    end

    def save(payload)
      file_name = File.join(@dir, "#{Time.now.to_i}.json")
      File.write(file_name, JSON.pretty_generate(payload))
    end
  end

  # Finally, a step to send a notificiation to the customer.
  # This should only run if the previous steps were successful.
  NotifyCustomer = proc do |result|
    # Send an email here.
    puts "Sending notification to #{result.value[:customer][:email]}"
    result
  end

  ###############################################################
  # Option 1: define standalone steps and then pipe them together
  ###############################################################
  CreateMortgageApplication1 = MortgagePayload \
    >> ValidateMortgageAmount \
    >> MortgageApplicationsStore \
    >> NotifyCustomer

  ###############################################################
  # Option 2: compose steps into a Plumb::Pipeline
  # This is just a wrapper around step1 >> step2 >> step3 ...
  # But the procedural style can make sequential steps easier to read and manage.
  # Also to add/remove debugging and tracing steps.
  ###############################################################
  CreateMortgageApplication2 = Any.pipeline do |pl|
    # The input payload
    pl.step MortgagePayload

    # Some inline logging to demostrate inline steps
    # This is also useful for debugging and tracing.
    pl.step do |result|
      p [:after_payload, result.value]
      result
    end

    # Domain validation
    pl.step ValidateMortgageAmount

    # Save the application
    pl.step MortgageApplicationsStore

    # Notifications
    pl.step NotifyCustomer
  end

  # Note that I could have also started the pipeline directly off the MortgagePayload type.
  # ex. CreateMortageApplication2 = MortgagePayload.pipeline do |pl
  # For super-tiny command objects you can do it all inline:
  #
  #   Types::Hash[
  #     name: String,
  #     age: Integer
  #   ].pipeline do |pl|
  #     pl.step do |result|
  #       .. some validations
  #       result
  #     end
  #   end
  #
  # Or you can use Method objects as steps
  #
  #   pl.step SomeObject.method(:create)

  ###############################################################
  # Option 3: use your own class
  # Use Plumb internally for validation and composition of shared steps or method objects.
  ###############################################################
  class CreateMortgageApplication3
    def initialize
      @pipeline = Types::Any.pipeline do |pl|
        pl.step MortgagePayload
        pl.step method(:validate)
        pl.step method(:save)
        pl.step method(:notify)
      end
    end

    def run(payload)
      @pipeline.call(payload)
    end

    private

    def validate(result)
      # etc
      result
    end

    def save(result)
      # etc
      result
    end

    def notify(result)
      # etc
      result
    end
  end
end

# Uncomment each case to run
# p Types::CreateMortgageApplication1.resolve(
#   customer: { name: 'John Doe', age: 30, email: 'john@doe.com' },
#   property_value: 200_000,
#   mortgage_amount: 150_000,
#   term: 25
# )

# p Types::CreateMortgageApplication2.resolve(
#   customer: { name: 'John Doe', age: 30, email: 'john@doe.com' },
#   property_value: 200_000,
#   mortgage_amount: 150_000,
#   term: 25
# )

# Or, with invalid data
# p Types::CreateMortgageApplication2.resolve(
#   customer: { name: 'John Doe', age: 30, email: 'john@doe.com' },
#   property_value: 200_000,
#   mortgage_amount: 201_000,
#   term: 25
# )

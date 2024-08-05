# frozen_string_literal: true

require 'plumb'
require 'time'
require 'uri'
require 'securerandom'
require 'debug'

# Bring Plumb into our own namespace
# and define some basic types
module Types
  include Plumb::Types

  # Turn an ISO8601 sring into a Time object
  ISOTime = String.build(::Time, :parse)

  # A type that can be a Time object or an ISO8601 string >> Time
  Time = Any[::Time] | ISOTime

  # A UUID string
  UUID = String[/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i]

  # A UUID string, or generate a new one
  AutoUUID = UUID.default { SecureRandom.uuid }

  Email = String[URI::MailTo::EMAIL_REGEXP]
end

# A superclass and registry to define event types
# for example for an event-driven or event-sourced system.
# All events have an "envelope" set of attributes,
# including unique ID, stream_id, type, timestamp, causation ID,
# event subclasses have a type string (ex. 'users.name.updated') and an optional payload
# This class provides a `.define` method to create new event types with a type and optional payload struct,
# a `.from` method to instantiate the correct subclass from a hash, ex. when deserializing from JSON or a web request.
# and a `#follow` method to produce new events based on a previous event's envelope, where the #causation_id and #correlation_id
# are set to the parent event
# @example
#
#  # Define event struct with type and payload
#  UserCreated = Event.define('users.created') do
#    attribute :name, Types::String
#    attribute :email, Types::Email
#  end
#
#  # Instantiate a full event with .new
#  user_created = UserCreated.new(stream_id: 'user-1', payload: { name: 'Joe', email: '...' })
#
#  # Use the `.from(Hash) => Event` factory to lookup event class by `type` and produce the right instance
#  user_created = Event.from(type: 'users.created', stream_id: 'user-1', payload: { name: 'Joe', email: '...' })
#
#  # Use #follow(payload Hash) => Event to produce events following a command or parent event
#  create_user = CreateUser.new(...)
#  user_created = create_user.follow(UserCreated, name: 'Joe', email: '...')
#  user_created.causation_id == create_user.id
#  user_created.correlation_id == create_user.correlation_id
#  user_created.stream_id == create_user.stream_id
#
# ## JSON Schemas
# Plumb data structs support `.to_json_schema`, to you can document all events in the registry with something like
#
#   Event.registry.values.map(&:to_json_schema)
#
class Event < Types::Data
  attribute :id, Types::AutoUUID
  attribute :stream_id, Types::String.present
  attribute :type, Types::String
  attribute(:created_at, Types::Time.default { ::Time.now })
  attribute? :causation_id, Types::UUID
  attribute? :correlation_id, Types::UUID
  attribute :payload, Types::Static[nil]

  def self.registry
    @registry ||= {}
  end

  def self.define(type_str, &payload_block)
    type_str.freeze unless type_str.frozen?
    registry[type_str] = Class.new(self) do
      attribute :type, Types::Static[type_str]
      attribute :payload, &payload_block if block_given?
    end
  end

  def self.from(attrs)
    klass = registry[attrs[:type]]
    raise ArgumentError, "Unknown event type: #{attrs[:type]}" unless klass

    klass.new(attrs)
  end

  def follow(event_class, payload_attrs = nil)
    attrs = { stream_id:, causation_id: id, correlation_id: }
    attrs[:payload] = payload_attrs if payload_attrs
    event_class.new(attrs)
  end
end

# Example command and events for a simple event-sourced system
#
# ## Commands
# CreateUser = Event.define('users.create') do
#   attribute :name, Types::String.present
#   attribute :email, Types::Email
# end
#
# UpdateUserName = Event.define('users.update_name') do
#   attribute :name, Types::String.present
# end
#
# ## Events
# UserCreated = Event.define('users.created') do
#   attribute :name, Types::String
#   attribute :email, Types::Email
# end
#
# UserNameUpdated = Event.define('users.name_updated') do
#   attribute :name, Types::String
# end
# debugger

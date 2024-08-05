# frozen_string_literal: true

require 'bundler/setup'
require 'plumb'
require 'debug'

# Types and pipelines for defining and parsing ENV configuration
# Run with `bundle exec ruby examples/env_config.rb`
#
# Given an ENV with variables to configure one of three types of network/IO clients,
# parse, validate and coerce the configuration into the appropriate client object.
# ENV vars are expected to be prefixed with `FILE_UPLOAD_`, followed by the client type.
# See example usage at the bottom of this file.
module Types
  include Plumb::Types

  # Define a custom policy to extract a string using a regular expression.
  # Policies are factories for custom type compositions.
  #
  # Usage:
  #   type = Types::String.extract(/^FOO_(\w+)$/).invoke(:[], 1)
  #   type.parse('FOO_BAR') # => 'BAR'
  #
  Plumb.policy :extract, for_type: ::String, helper: true do |type, regex|
    type >> lambda do |result|
      match = result.value.match(regex)
      return result.invalid(errors: "does not match #{regex.source}") if match.nil?
      return result.invalid(errors: 'no captures') if match.captures.none?

      result.valid(match)
    end
  end

  # A dummy S3 client
  S3Client = ::Data.define(:bucket, :region)

  # A dummy SFTP client
  SFTPClient = ::Data.define(:host, :username, :password)

  # Map these fields to an S3 client
  S3Config = Types::Hash[
    transport: 's3',
    bucket: String.present,
    region: String.options(%w[us-west-1 us-west-2 us-east-1])
  ].invoke(:except, :transport).build(S3Client) { |h| S3Client.new(**h) }

  # Map these fields to an SFTP client
  SFTPConfig = Types::Hash[
    transport: 'sftp',
    host: String.present,
    username: String.present,
    password: String.present,
  ].invoke(:except, :transport).build(SFTPClient) { |h| SFTPClient.new(**h) }

  # Map these fields to a File client
  FileConfig = Types::Hash[
    transport: 'file',
    path: String.present,
  ].invoke(:[], :path).build(::File)

  # Take a string such as 'FILE_UPLOAD_BUCKET', extract the `BUCKET` bit,
  # downcase and symbolize it.
  FileUploadKey = String.extract(/^FILE_UPLOAD_(\w+)$/).invoke(:[], 1).invoke(%i[downcase to_sym])

  # Filter a Hash (or ENV) to keys that match the FILE_UPLOAD_* pattern
  FileUploadHash = Types::Hash[FileUploadKey, Any].filtered

  # Pipeline syntax to put the program together
  FileUploadClientFromENV = Any.pipeline do |pl|
    # 1. Accept any Hash-like object (e.g. ENV)
    pl.step Types::Interface[:[], :key?, :each, :to_h]

    # 2. Transform it to a Hash
    pl.step Any.transform(::Hash, &:to_h)

    # 3. Filter keys with FILE_UPLOAD_* prefix
    pl.step FileUploadHash

    # 4. Parse the configuration for a particular client object
    pl.step(S3Config | SFTPConfig | FileConfig)
  end

  # Ex.
  # client = FileUploadClientFromENV.parse(ENV) # SFTP, S3 or File client

  # The above is the same as:
  #
  # FileUploadClientFromENV = Types::Interface[:[], :key?, :each, :to_h] \
  #                           .transform(::Hash, &:to_h) >> \
  #                           Types::Hash[FileUploadKey, Any].filtered >> \
  #                           (S3Config | SFTPConfig | FileConfig)
end

# Simulated ENV hashes. Just use ::ENV for the real thing.
ENV_S3 = {
  'FILE_UPLOAD_TRANSPORT' => 's3',
  'FILE_UPLOAD_BUCKET' => 'my-bucket',
  'FILE_UPLOAD_REGION' => 'us-west-2',
  'SOMETHING_ELSE' => 'ignored'
}.freeze
# => S3Client.new(bucket: 'my-bucket', region: 'us-west-2')

ENV_SFTP = {
  'FILE_UPLOAD_TRANSPORT' => 'sftp',
  'FILE_UPLOAD_HOST' => 'sftp.example.com',
  'FILE_UPLOAD_USERNAME' => 'username',
  'FILE_UPLOAD_PASSWORD' => 'password',
  'SOMETHING_ELSE' => 'ignored'
}.freeze
# => SFTPClient.new(host: 'sftp.example.com', username: 'username', password: 'password')

ENV_FILE = {
  'FILE_UPLOAD_TRANSPORT' => 'file',
  'FILE_UPLOAD_PATH' => File.join('examples', 'programmers.csv')
}.freeze

p Types::FileUploadClientFromENV.parse(ENV_S3) # #<data Types::S3Client bucket="my-bucket", region="us-west-2">
p Types::FileUploadClientFromENV.parse(ENV_SFTP) # #<data Types::SFTPClient host="sftp.example.com", username="username", password="password">
p Types::FileUploadClientFromENV.parse(ENV_FILE) # #<File path="examples/programmers.csv">

# Or with invalid or missing configuration
# p Types::FileUploadClientFromENV.parse({}) # raises error

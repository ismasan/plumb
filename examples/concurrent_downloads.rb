# frozen_string_literal: true

require 'bundler'
Bundler.setup(:examples)
require 'plumb'
require 'open-uri'
require 'fileutils'
require 'digest/md5'

# Mixin built-in Plumb types, and provide a namespace for core types and
# pipelines in this example.
module Types
  include Plumb::Types

  # Turn a string into an URI
  URL = String[/^https?:/].build(::URI, :parse)

  # a Struct to holw image data
  Image = Data.define(:url, :io)

  # A (naive) step to download files from the internet
  # and return an Image struct.
  # It implements the #call(Result) => Result interface.
  # required by all Plumb steps.
  # URI => Image
  Download = Plumb::Step.new do |result|
    io = URI.open(result.value)
    result.valid(Image.new(result.value.to_s, io))
  end

  # A configurable file-system cache to read and write files from.
  class Cache
    def initialize(dir = '.')
      @dir = dir
      FileUtils.mkdir_p(dir)
    end

    # Wrap the #reader and #wruter methods into Plumb steps
    # A step only needs #call(Result) => Result to work in a pipeline,
    # but wrapping it in Plumb::Step provides the #>> and #| methods for composability,
    # as well as all the other helper methods provided by the Steppable module.
    def read = Plumb::Step.new(method(:reader))
    def write = Plumb::Step.new(method(:writer))

    private

    # URL => Image
    def reader(result)
      path = path_for(result.value)
      return result.invalid(errors: "file #{path} does not exist") unless File.exist?(path)

      result.valid Types::Image.new(url: path, io: File.new(path))
    end

    # Image => Image
    def writer(result)
      image = result.value
      path = path_for(image.url)
      File.open(path, 'wb') { |f| f.write(image.io.read) }
      result.valid image.with(url: path, io: File.new(path))
    end

    def path_for(url)
      url = url.to_s
      ext = File.extname(url)
      name = [Digest::MD5.hexdigest(url), ext].compact.join
      File.join(@dir, name)
    end
  end
end

###################################
# Program 1: idempoent download of images from the internet
# If not present in the cache, images are downloaded and written to the cache.
# Otherwise images are listed directly from the cache (files on disk).
###################################

cache = Types::Cache.new('./examples/data/downloads')

# A pipeline representing a single image download.
# 1). Take a valid URL string.
# 2). Attempt reading the file from the cache. Return that if it exists.
# 3). Otherwise, download the file from the internet and write it to the cache.
IdempotentDownload = Types::URL >> (cache.read | (Types::Download >> cache.write))

# An array of downloadable images,
# marked as concurrent so that all IO operations are run in threads.
Images = Types::Array[IdempotentDownload].concurrent

urls = [
  'https://as1.ftcdn.net/v2/jpg/07/67/24/52/1000_F_767245234_NdiDr9LOkypOEKtXiDDoM1m42zBQ0hZe.jpg',
  'https://as1.ftcdn.net/v2/jpg/07/83/02/00/1000_F_783020069_HaP9UCZs2UXUnKxpGHDoddt0vuX4vU9U.jpg',
  'https://as2.ftcdn.net/v2/jpg/07/32/27/53/1000_F_732275398_r2t1cnxSXGUkZSgxtqhg40UupKiqcywJ.jpg',
  'https://as1.ftcdn.net/v2/jpg/07/46/41/18/1000_F_746411866_WwQBojO7xMeVFTua2BuEZdKGDI2vsgAH.jpg',
  'https://as2.ftcdn.net/v2/jpg/07/43/50/53/1000_F_743505311_MJ3zo09rH7rUvHrCKlBotojm6GLw3SCT.jpg',
  'https://images.pexels.com/photos/346529/pexels-photo-346529.jpeg'
]

# raise CachedDownload.parse(url).inspect
# raise CachedDownload.parse(urls.first).inspect
# Run the program. The images are downloaded and written to the ./downloads directory.
# Running this multiple times will only download the images once, and list them from the cache.
# You can try deleting all or some of the files and re-running.
Images.resolve(urls).tap do |result|
  puts result.valid? ? 'valid!' : result.errors
  result.value.each { |img| p img }
end

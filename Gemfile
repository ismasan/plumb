# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in plumb.gemspec
gemspec

gem 'money'

group :development do
  gem 'csv'
  gem 'debug'
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.0'
  gem 'rubocop', require: false
  gem 'docco', github: 'ismasan/docco'
end

group :benchmark do
  gem 'ruby-prof'
  gem 'benchmark'
  gem 'benchmark-ips'
  gem 'memory_profiler'
  gem 'monetize'
  gem 'parametric'
  gem 'dry-types'
  gem 'dry-schema'
end

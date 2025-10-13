# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in plumb.gemspec
gemspec

gem 'money'

group :development do
  gem 'debug'
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.0'
  gem 'rubocop', require: false
  gem 'docco', github: 'ismasan/docco'
end

group :benchmark do
  gem 'benchmark-ips'
  gem 'monetize'
  gem 'parametric'
end

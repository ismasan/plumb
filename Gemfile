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
end

group :benchmark do
  gem 'benchmark-ips'
  gem 'monetize'
  gem 'parametric'
end

group :docs do
  gem 'kramdown'
  gem 'kramdown-parser-gfm'
end

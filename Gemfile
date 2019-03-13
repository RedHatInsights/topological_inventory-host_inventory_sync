source 'https://rubygems.org'

plugin "bundler-inject", "~> 1.1"
require File.join(Bundler::Plugin.index.load_paths("bundler-inject")[0], "bundler-inject") rescue nil

gem "activesupport"
gem "concurrent-ruby"
gem "manageiq-loggers", "~> 0.1.0"
gem "manageiq-messaging"
gem "more_core_extensions"
gem "optimist"
gem "rest-client"

gem "topological_inventory-ingress_api-client", :git => "https://github.com/ManageIQ/topological_inventory-ingress_api-client-ruby", :branch => "master"

group :development, :test do
  gem "rake"
  gem "rspec"
  gem "simplecov"
  gem "webmock"
end

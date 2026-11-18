require_relative "../config/environment"
require "rspec/rails"
require "capybara/rspec"
RSpec.configure { |config| config.include Rails.application.routes.url_helpers }

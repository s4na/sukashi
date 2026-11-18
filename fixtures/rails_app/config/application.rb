require "action_controller/railtie"

class OrderApp < Rails::Application
  config.load_defaults 8.1
  config.root = File.expand_path("..", __dir__)
  config.eager_load = false
  config.action_controller.allow_forgery_protection = false if Rails.env.test?
  config.hosts += %w[example.org www.example.com 127.0.0.1]
  config.secret_key_base = "test-only-" * 8
  config.logger = Logger.new(File::NULL)
end

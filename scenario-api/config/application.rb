require 'bundler/setup'
require 'rails'
require 'action_controller/railtie'
require 'logger'
require_relative '../lib/scenario/service'
require_relative '../lib/scenario/request_limits'

module ScenarioApi
  class Application < Rails::Application
    config.load_defaults 7.2
    config.api_only = true
    config.middleware.insert_before 0, Scenario::RequestLimits
    config.eager_load = true
    config.secret_key_base = 'unused-api-only-no-sessions-or-cookies'
    config.hosts = ENV.fetch('SCENARIO_ALLOWED_HOSTS', 'scenario-api,localhost,127.0.0.1').split(',')
    config.logger = Logger.new($stdout)
    config.log_level = :warn
    config.filter_parameters = [/.*/]
    config.action_dispatch.show_exceptions = :none
    config.autoload_paths << File.expand_path('../app/controllers', __dir__)
  end
end

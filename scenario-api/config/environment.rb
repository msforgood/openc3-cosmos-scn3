require_relative 'application'
require_relative '../lib/scenario/runtime'
ScenarioApi::Application.initialize!
Scenario::Runtime.start! unless ENV['SCENARIO_TEST'] == '1'

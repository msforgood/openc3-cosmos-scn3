# Run inside the 6.10.1 Ruby image, with no network and no deployment writes.
require 'openc3'
require 'openc3/models/target_model'
require 'openc3/config/config_parser'
require 'ostruct'

# TargetModel initialization ordinarily gets a bucket client. No bucket is
# needed to validate supported configuration or an empty deployment plan.
module OpenC3
  class Bucket
    def self.getClient
      Object.new
    end
  end
end

model = OpenC3::TargetModel.new(name: 'SCENARIO_RUNNER', scope: 'DEFAULT')
parser = OpenC3::ConfigParser.new
parser.parse_file(File.expand_path('../plugin.txt', __dir__)) do |keyword, parameters|
  next if keyword == 'TARGET'
  model.handle_config(parser, keyword, parameters)
end
expected = %w[DECOM COMMANDLOG DECOMCMDLOG PACKETLOG DECOMLOG REDUCER CLEANUP]
raise 'missing explicit microservice designation' unless expected.all? { |name| model.target_microservices[name] }
empty_packets = Object.new
def empty_packets.packets(_name)
  {}
end
system = OpenStruct.new(commands: empty_packets, telemetry: empty_packets)
model.singleton_class.class_eval do
  %w[deploy_multi_microservice deploy_cleanup_microservice deploy_reducer_microservice deploy_decom_microservice deploy_packetlog_microservice deploy_decomlog_microservice deploy_commmandlog_microservice deploy_decomcmdlog_microservice].each do |method|
    define_method(method) { |*args| raise "unexpected auxiliary service: #{method}" }
  end
end
model.deploy_microservices('/unused', {}, system)
puts 'OpenC3 target configuration: valid syntax; zero auxiliary services for empty SCENARIO_RUNNER'

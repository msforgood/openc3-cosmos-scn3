require 'openc3/utilities/migration'
require 'openc3/models/scope_model'
require 'openc3/models/microservice_model'

module OpenC3
  class TimelineMicroserviceWorkDir < Migration
    begin
      require 'openc3-enterprise/models/cmd_authority_model'
      BASE = false
    rescue LoadError
      BASE = true
    end

    # The timeline microservice is provided by COSMOS Core so point any
    # existing timeline microservices back at the core microservices folder
    def self.run
      return unless BASE
      ScopeModel.get_all_models(scope: nil).each do |scope, _scope_model|
        MicroserviceModel.get_all_models(scope: scope).each do |microservice_name, microservice_model|
          next unless microservice_name =~ /__TIMELINE__/
          next if microservice_model.work_dir == '/openc3/lib/openc3/microservices'
          microservice_model.work_dir = '/openc3/lib/openc3/microservices'
          microservice_model.update
        end
      end
    end
  end
end

unless ENV['OPENC3_NO_MIGRATE']
  OpenC3::TimelineMicroserviceWorkDir.run
end

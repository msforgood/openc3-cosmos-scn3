module Scenario
  module Runtime
    class << self
      attr_accessor :service

      def healthy?
        service && (ENV['SCENARIO_TEST'] == '1' || @thread&.alive?)
      end

      def start!
        require_relative 'openc3_adapter'
        require_relative 'installed_release'
        path = ENV.fetch('SCENARIO_DB', '/data/scenario.sqlite3')
        FileUtils.mkdir_p(File.dirname(path))
        @lock = File.open("#{path}.instance-lock", File::RDWR | File::CREAT, 0o600)
        raise 'Scenario API requires exactly one service instance per database' unless @lock.flock(File::LOCK_EX | File::LOCK_NB)
        catalog_path = ENV.fetch('SCENARIO_CATALOG', File.expand_path('../../config/scenarios.json', __dir__))
        InstalledRelease.new(state_directory: File.dirname(path), catalog: catalog_path,
                             scope: ENV.fetch('SCENARIO_SCOPE', 'DEFAULT')).verify!
        @store = Store.new(path)
        catalog = Catalog.new(path: catalog_path)
        adapter = OpenC3Adapter.new(
          script_api_url: ENV.fetch('SCENARIO_SCRIPT_API_URL', 'http://openc3-cosmos-script-runner-api:2902'),
          public_api_url: ENV.fetch('SCENARIO_PUBLIC_API_URL', 'http://scenario-api:2910/scenario-api'),
          policy_path: File.join(File.dirname(catalog_path), 'safety_policy.json')
        )
        self.service = Service.new(store: @store, catalog: catalog, backend: adapter, auth: Authentication.new)
        @thread = Thread.new do
          begin
            service.recover!
          rescue StandardError
            $stderr.puts('Scenario startup reconciliation temporarily unavailable')
          end
          loop do
            sleep 2
            service.reconcile_all
          rescue StandardError
            # Keep recovery alive; status remains unknown and all unresolved locks survive.
            $stderr.puts('Scenario reconciliation temporarily unavailable')
          end
        end
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
        at_exit { @thread&.kill; @store&.close; @lock&.close }
      rescue StandardError
        @thread&.kill
        @store&.close
        @lock&.close
        self.service = nil
        raise
      end
    end
  end
end

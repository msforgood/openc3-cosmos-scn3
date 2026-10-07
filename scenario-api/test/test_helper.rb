ENV['SCENARIO_TEST'] = '1'
ENV['RAILS_ENV'] = 'test'
require 'minitest/autorun'
require 'tmpdir'
require 'timeout'
require_relative '../lib/scenario/service'

class FakeAuth
  attr_reader :calls
  attr_accessor :deny
  def initialize
    @calls = []
  end
  def authorize!(**args)
    @calls << args.reject { |key, _| key == :token }
    raise Scenario::Error.new('unauthenticated', nil, 401) unless args[:token] == 'valid-test-credential'
    raise Scenario::Error.new('forbidden', nil, 403) if @deny && @deny.call(args)
    true
  end
end

class FakeBackend
  attr_accessor :launch_error, :during_launch, :validation_error, :status_error
  attr_reader :launches, :statuses, :stops
  def initialize
    @launches, @statuses, @stops, @mutex = [], {}, [], Mutex.new
  end
  def validate_definition!(*_args)
    raise @validation_error if @validation_error
  end
  def launch(run, _token)
    id = @mutex.synchronize do
      @launches << run
      (@launches.size + 100).to_s
    end
    @statuses[[run['scope'], id]] = {
      'name' => id, 'state' => 'running', 'filename' => Scenario::Service::PROCEDURE, 'end_time' => nil,
      'environment' => { 'SCENARIO_RUN_ID' => run['id'], 'SCENARIO_DEFINITION_HASH' => run['definition_hash'] }
    }
    @during_launch&.call(run, id)
    raise @launch_error if @launch_error
    id
  end
  def status(scope, id)
    raise @status_error if @status_error
    @statuses[[scope, id]]
  end
  def find(run)
    raise @status_error if @status_error
    @statuses.select { |(scope, _), _| scope == run['scope'] }.values
  end
  def stop(run)
    @stops << run['id']
  end
end

class ScenarioTest < Minitest::Test
  TOKEN = 'valid-test-credential'
  def setup
    @dir = Dir.mktmpdir('scenario-api-test')
    @db = File.join(@dir, 'runs.sqlite3')
    @store = Scenario::Store.new(@db)
    @catalog = Scenario::Catalog.new(path: File.expand_path('../config/scenarios.json', __dir__))
    @auth, @backend = FakeAuth.new, FakeBackend.new
    @time = Time.utc(2026, 9, 27, 12)
    @service = build_service
  end
  def teardown
    @store.close
    FileUtils.remove_entry(@dir)
  end
  def build_service(store = @store, max_active: 4)
    Scenario::Service.new(store: store, catalog: @catalog, backend: @backend, auth: @auth, clock: -> { @time }, max_active: max_active)
  end
  def input(key = 'request-0001', scope: 'DEFAULT')
    d = @catalog.definitions.first
    { 'scope' => scope, 'target' => 'CFS-1_QEMU', 'scenario_id' => d['id'],
      'definition_version' => d['version'], 'definition_hash' => Scenario::Canonical.hash(d), 'request_id' => key }
  end
  def create(key = 'request-0001', **opts)
    @service.create(input(key, **opts), token: TOKEN).first
  end
  def detail(run)
    @service.get(run['id'], scope: run['scope'], token: TOKEN)
  end
  def callback(run, type, data = {}, event_id: SecureRandom.uuid, script_id: run['script_id'])
    @service.callback(run['id'], scope: run['scope'], token: TOKEN,
                      payload: { 'type' => type, 'script_id' => script_id, 'event_id' => event_id, 'data' => data })
  end
  def assert_error(code, &block)
    error = assert_raises(Scenario::Error, &block)
    assert_equal code, error.code
    error
  end
  def terminal(run, state = 'completed')
    @backend.statuses.fetch([run['scope'], run['script_id']]).merge!('state' => state, 'end_time' => @time.iso8601)
    @service.reconcile(run['id'])
  end
end

require 'sqlite3'
require 'fileutils'
require 'json'
require_relative 'errors'

module Scenario
  class Store
    TERMINAL = %w[succeeded failed stopped].freeze
    MAX_EVENTS = 1000
    MAX_RUNS = 10_000
    attr_reader :path

    def initialize(path)
      @path, @mutex = path, Mutex.new
      FileUtils.mkdir_p(File.dirname(path)) unless path == ':memory:'
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      @db.busy_timeout = 5000
      @db.execute('PRAGMA journal_mode=WAL')
      @db.execute('PRAGMA synchronous=FULL')
      @db.execute('PRAGMA foreign_keys=ON')
      @db.execute('PRAGMA journal_size_limit=16777216')
      @db.execute('PRAGMA max_page_count=131072')
      @db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS runs (
          id TEXT PRIMARY KEY, scope TEXT NOT NULL, target TEXT NOT NULL,
          request_id TEXT NOT NULL, fingerprint TEXT NOT NULL, state TEXT NOT NULL,
          script_id TEXT, created_at TEXT NOT NULL, data TEXT NOT NULL,
          UNIQUE(scope, request_id), UNIQUE(scope, script_id)
        );
        CREATE TABLE IF NOT EXISTS locks (
          scope TEXT NOT NULL, target TEXT NOT NULL, run_id TEXT NOT NULL UNIQUE REFERENCES runs(id),
          PRIMARY KEY(scope, target)
        );
        CREATE TABLE IF NOT EXISTS events (
          id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL REFERENCES runs(id),
          event_id TEXT, fingerprint TEXT, type TEXT NOT NULL, data TEXT NOT NULL, created_at TEXT NOT NULL,
          UNIQUE(run_id, event_id)
        );
        CREATE INDEX IF NOT EXISTS events_run ON events(run_id, id);
        CREATE INDEX IF NOT EXISTS runs_scope_target ON runs(scope, target, created_at);
        PRAGMA user_version=1;
      SQL
    end

    def transaction
      @mutex.synchronize do
        @db.execute('BEGIN IMMEDIATE')
        begin
          result = yield self
          @db.execute('COMMIT')
          result
        rescue Exception
          @db.execute('ROLLBACK') if @db.transaction_active?
          raise
        end
      end
    rescue SQLite3::BusyException
      raise Error.new('database_busy', nil, 503)
    end

    # The methods below are intentionally transaction-only; never hold the transaction across network I/O.
    def get(id)
      row = @db.get_first_row('SELECT data FROM runs WHERE id=?', [id])
      row && JSON.parse(row['data'])
    end

    def by_request(scope, request_id)
      row = @db.get_first_row('SELECT data FROM runs WHERE scope=? AND request_id=?', [scope, request_id])
      row && JSON.parse(row['data'])
    end

    def insert(run, max_active:)
      lock = @db.get_first_value('SELECT run_id FROM locks WHERE scope=? AND target=?', [run['scope'], run['target']])
      raise Error.new('target_locked', nil, 409) if lock
      raise Error.new('active_capacity', nil, 429) if @db.get_first_value('SELECT COUNT(*) FROM locks') >= max_active
      insert_record(run)
      @db.execute('INSERT INTO locks(scope,target,run_id) VALUES(?,?,?)', [run['scope'],run['target'],run['id']])
    end

    def insert_failed_request(run)
      unless run['state'] == 'failed' && run['error'] == 'request_not_accepted' &&
             run['termination_confirmed'] == true && run['launch_pending'] == false && run['script_id'].nil?
        raise Error.new('invalid_failed_request')
      end
      insert_record(run)
    end

    def insert_record(run)
      raise Error.new('record_capacity', nil, 429) if @db.get_first_value('SELECT COUNT(*) FROM runs') >= MAX_RUNS
      @db.execute('INSERT INTO runs(id,scope,target,request_id,fingerprint,state,created_at,data) VALUES(?,?,?,?,?,?,?,?)',
                  [run['id'],run['scope'],run['target'],run['request_id'],run['fingerprint'],run['state'],run['created_at'],JSON.generate(run)])
    end
    private :insert_record

    def save(run)
      @db.execute('UPDATE runs SET state=?,script_id=?,data=? WHERE id=?', [run['state'],run['script_id'],JSON.generate(run),run['id']])
      if TERMINAL.include?(run['state']) && run['termination_confirmed']
        @db.execute('DELETE FROM locks WHERE run_id=?', [run['id']])
      end
    end

    def list(scope:, target: nil, limit: 25)
      sql, args = 'SELECT data FROM runs WHERE scope=?', [scope]
      if target
        sql += ' AND target=?'
        args << target
      end
      # Recovery fences count toward history; keep the actual lock owner visible
      # even when more than one history page of failed requests was recorded.
      sql += ' ORDER BY EXISTS(SELECT 1 FROM locks WHERE locks.run_id=runs.id) DESC,created_at DESC,id DESC LIMIT ?'
      @db.execute(sql, args + [limit]).map { |r| JSON.parse(r['data']) }
    end

    def active
      @db.execute('SELECT runs.data FROM runs JOIN locks ON runs.id=locks.run_id').map { |r| JSON.parse(r['data']) }
    end

    def event_replay(run_id, event_id, fingerprint)
      row = @db.get_first_row('SELECT fingerprint FROM events WHERE run_id=? AND event_id=?', [run_id,event_id])
      return false unless row
      raise Error.new('event_conflict', nil, 409) unless row['fingerprint'] == fingerprint
      true
    end

    def event(run_id, type, data, time:, event_id: nil, fingerprint: nil)
      count = @db.get_first_value('SELECT COUNT(*) FROM events WHERE run_id=?', [run_id])
      # Reserve a few events for terminal transitions/stop after callback saturation.
      raise Error.new('event_capacity', nil, 429) if count >= MAX_EVENTS && event_id
      return if count >= MAX_EVENTS + 16
      @db.execute('INSERT INTO events(run_id,event_id,fingerprint,type,data,created_at) VALUES(?,?,?,?,?,?)',
                  [run_id,event_id,fingerprint,type,JSON.generate(data),time])
    end

    def events(id, after:, limit:)
      @db.execute('SELECT id,run_id,type,data,created_at FROM events WHERE run_id=? AND id>? ORDER BY id LIMIT ?',
                  [id,after,limit]).map { |r| r.merge('data' => JSON.parse(r['data'])) }
    end

    def close
      @mutex.synchronize { @db.close }
    end

    def prompt_used?(id, prompt_id)
      @db.execute("SELECT data FROM events WHERE run_id=? AND type='prompt'", [id]).any? { |e| JSON.parse(e['data'])['prompt_id'] == prompt_id }
    end
  end
end

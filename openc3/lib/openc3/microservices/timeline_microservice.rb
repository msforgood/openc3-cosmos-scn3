# encoding: ascii-8bit

# Copyright 2022 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU Affero General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# Modified by OpenC3, Inc.
# All changes Copyright 2025, OpenC3, Inc.
# All Rights Reserved
#
# This file may also be used under the terms of a commercial license
# if purchased from OpenC3, Inc.

require 'openc3/utilities/authentication'
require 'openc3/microservices/microservice'
require 'openc3/models/activity_model'
require 'openc3/models/timeline_model'
require 'openc3/models/auth_model'
require 'openc3/models/offline_access_model'
require 'openc3/models/script_status_model'
require 'openc3/topics/timeline_topic'

require 'openc3/utilities/sleeper'
require 'openc3/script'
require 'net/http'

module OpenC3
  # The Timeline worker is a very simple thread pool worker. Once
  # the timeline manager has pushed a job to the schedule one of
  # these workers will run the CMD (command) or SCRIPT (script)
  # or anything that could be expanded in the future.
  class TimelineWorker
    def initialize(name:, logger:, scope:, queue:, script_monitor: nil)
      @timeline_name = name
      @logger = logger
      @scope = scope
      @queue = queue
      @script_monitor = script_monitor
    end

    # Returns the token used to run the activity. When the service password is not
    # available (it is intentionally removed from the operator container so a shell
    # there can't simply use the script API) a short lived session token is issued
    # instead and must be released with release_token once the activity has run.
    def get_token(username)
      if ENV['OPENC3_API_CLIENT'].nil?
        service_password = ENV['OPENC3_SERVICE_PASSWORD'].to_s
        return service_password unless service_password.empty?
        return AuthModel.generate_session
      else
        # Check for offline access token
        model = nil
        model = OpenC3::OfflineAccessModel.get_model(name: username, scope: @scope) if username and username != ''
        if model and model.offline_access_token
          auth = OpenC3KeycloakAuthentication.new(ENV['OPENC3_KEYCLOAK_URL'])
          return auth.get_token_from_refresh_token(model.offline_access_token)
        else
          return nil
        end
      end
    end

    def release_token(token)
      return if token.nil? or token == ENV['OPENC3_SERVICE_PASSWORD'] or !ENV['OPENC3_API_CLIENT'].nil?
      Store.hdel(AuthModel::SESSIONS_KEY, token)
    rescue StandardError => e
      @logger.error "#{@timeline_name} failed to release session token: #{e.message}"
    end

    def run
      @logger.info "#{@timeline_name} timeline worker running"
      loop do
        activity = @queue.pop
        break if activity.nil?

        run_activity(activity)
      end
      @logger.info "#{@timeline_name} timeline worker exiting"
    end

    def run_activity(activity)
      case activity.kind.downcase
      when 'command'
        run_command(activity)
      when 'script'
        run_script(activity)
      when 'expire'
        clear_expired(activity)
      when 'reserve'
        # Reserve activities only hold space on the timeline
      else
        @logger.error "Unknown kind passed to microservice #{@timeline_name}: #{activity.as_json}"
      end
    end

    # Execution is enabled / disabled per timeline via the TimelineModel execute flag
    def execute_enabled?
      timeline = TimelineModel.get(name: @timeline_name, scope: @scope)
      return true if timeline.nil? # Default is execute
      return timeline.execute
    end

    def run_command(activity)
      @logger.info "#{@timeline_name} run_command > #{activity.as_json}"
      token = nil
      begin
        if execute_enabled?()
          username = activity.data['username']
          token = get_token(username)
          raise "No token available for username: #{username}" unless token
          cmd_no_hazardous_check(activity.data['command'], scope: @scope, token: token)
          activity.commit(status: 'completed', message: activity.data['command'], fulfillment: true)
        else
          activity.commit(status: 'disabled', message: 'Execution is disabled')
          @logger.warn "#{@timeline_name} run_command disabled > #{activity.as_json}"
        end
      rescue StandardError => e
        activity.commit(status: 'failed', message: e.message)
        @logger.error "#{@timeline_name} run_command failed > #{activity.as_json}, #{e.formatted}"
      ensure
        release_token(token)
      end
    end

    def run_script(activity)
      @logger.info "#{@timeline_name} run_script > #{activity.as_json}"
      token = nil
      begin
        if execute_enabled?()
          username = activity.data['username']
          token = get_token(username)
          raise "No token available for username: #{username}" unless token
          request = Net::HTTP::Post.new(
            "/script-api/scripts/#{activity.data['script']}/run?scope=#{@scope}",
            'Content-Type' => 'application/json',
            'Authorization' => token
          )
          request.body = JSON.generate({
            'scope' => @scope,
            'environment' => activity.data['environment'],
            'timeline' => @timeline_name,
            'id' => activity.start
          })
          hostname = ENV['OPENC3_SCRIPT_HOSTNAME'] || 'openc3-cosmos-script-runner-api'
          response = Net::HTTP.new(hostname, 2902).request(request)
          raise "failed to call #{hostname}, for script: #{activity.data['script']}, response code: #{response.code}" if response.code != '200'

          script_id = response.body.to_s.strip
          activity.commit(status: 'started', message: "#{activity.data['script']} => #{script_id}", fulfillment: true)
          # Track the running script so its lifecycle is recorded on the activity
          @script_monitor.add(script_id, activity) if @script_monitor and !script_id.empty?
        else
          activity.commit(status: 'disabled', message: 'Execution is disabled')
          @logger.warn "#{@timeline_name} run_script disabled > #{activity.as_json}"
        end
      rescue StandardError => e
        activity.commit(status: 'failed', message: e.message)
        @logger.error "#{@timeline_name} run_script failed > #{activity.as_json}, #{e.message}"
      ensure
        release_token(token)
      end
    end

    def clear_expired(activity)
      begin
        num = ActivityModel.range_destroy(name: @timeline_name, scope: @scope, min: activity.start, max: activity.stop)
        @logger.info "#{@timeline_name} clear_expired removed #{num} items from #{activity.start} to #{activity.stop}"
        activity.add_event(status: 'completed')
      rescue StandardError => e
        @logger.error "#{@timeline_name} clear_expired failed > #{activity.as_json} #{e.message}"
      end
    end
  end

  # Lifecycle hooks for script activities. Watches the status of scripts
  # started by the timeline and commits an event to the activity every
  # time the script changes state until the script completes.
  class TimelineScriptMonitor
    # ScriptStatusModel state => activity event
    # waiting is just running inside a wait() so it is reported as running
    STATE_EVENTS = {
      'running' => 'running',
      'waiting' => 'running',
      'paused' => 'paused',
      'breakpoint' => 'breakpoint',
      'error' => 'error',
      'crashed' => 'crashed',
      'stopped' => 'stopped',
      'killed' => 'killed',
      'completed' => 'completed',
      'completed_errors' => 'completed_errors',
    }
    COMPLETE_STATES = %w(completed completed_errors stopped crashed killed)
    # Number of consecutive checks a script status can be missing before we give up
    MAX_MISSING = 60

    def initialize(name:, logger:, scope:, period: 1)
      @timeline_name = name
      @logger = logger
      @scope = scope
      @period = period
      @scripts = {}
      @mutex = Mutex.new
      @sleeper = Sleeper.new
      @cancel_thread = false
    end

    # Keep the activity itself because once the activity start has passed it can
    # no longer be loaded via ActivityModel (validation requires a future start)
    def add(script_id, activity)
      @mutex.synchronize do
        @scripts[script_id.to_s] = { 'activity' => activity, 'event' => nil, 'missing' => 0 }
      end
    end

    def remove(script_id)
      @mutex.synchronize { @scripts.delete(script_id.to_s) }
    end

    def script_ids
      @mutex.synchronize { @scripts.keys }
    end

    def run
      @logger.info "#{@timeline_name} timeline script monitor running"
      loop do
        break if @cancel_thread
        check_scripts()
        break if @sleeper.sleep(@period)
      end
      @logger.info "#{@timeline_name} timeline script monitor exiting"
    end

    def check_scripts
      scripts = @mutex.synchronize { @scripts.dup }
      scripts.each do |script_id, info|
        begin
          status = ScriptStatusModel.get(name: script_id, scope: @scope)
          if status.nil?
            info['missing'] += 1
            if info['missing'] >= MAX_MISSING
              @logger.warn "#{@timeline_name} script monitor lost track of script #{script_id}"
              remove(script_id)
            end
            next
          end
          info['missing'] = 0
          state = status['state']
          event = STATE_EVENTS[state]
          if event and event != info['event']
            info['event'] = event
            activity = info['activity']
            unless activity_exists?(activity)
              # Activity was removed so stop tracking the script
              remove(script_id)
              next
            end
            message = "#{status['filename']} (#{script_id}) #{state}"
            if status['errors'] and !status['errors'].empty?
              message << ": #{Array(status['errors']).join(', ')}"
            end
            activity.commit(status: event, message: message)
          end
          remove(script_id) if COMPLETE_STATES.include?(state)
        rescue StandardError => e
          @logger.error "#{@timeline_name} script monitor failed for script #{script_id}\n#{e.formatted}"
        end
      end
    end

    def activity_exists?(activity)
      values = Store.zrangebyscore("#{@scope}#{ActivityModel::PRIMARY_KEY}__#{@timeline_name}", activity.start, activity.start)
      values.any? { |value| JSON.parse(value, allow_nan: true, create_additions: true)['uuid'] == activity.uuid }
    end

    def shutdown
      @cancel_thread = true
      @sleeper.cancel
    end
  end

  # Shared between the monitor thread and the manager thread to
  # share the planned activities. This should remain a thread
  # safe implementation.
  class Schedule
    def initialize(name)
      @name = name
      @activities_mutex = Mutex.new
      @activities = []
      # This can stay relatively small since it's only the currently queued
      # activities. Once a worker thread processes it we no longer care.
      @size = 20
      @queue = Array.new(@size)
      @index = 0
    end

    def not_queued?(activity)
      return false if @queue.index(activity.uuid)
      @queue[@index] = activity.uuid
      @index = @index + 1 >= @size ? 0 : @index + 1
      return true
    end

    def activities
      @activities_mutex.synchronize do
        return @activities.dup
      end
    end

    def update(input_activities)
      @activities_mutex.synchronize do
        @activities = input_activities.dup
      end
    end

    def add_activity(activity)
      @activities_mutex.synchronize do
        @activities << activity
      end
    end

    def remove_activity(data)
      @activities_mutex.synchronize do
        @activities.delete_if do |a|
          a.start == data['start'] && a.uuid == data['uuid']
        end
      end
    end
  end

  # The timeline manager starts a thread pool and looks at the
  # schedule and if an "activity" should be run. TimelineManager
  # adds the "activity" to the thread pool and the thread will
  # execute the "activity".
  class TimelineManager
    def initialize(name:, logger:, scope:, schedule:)
      @timeline_name = name
      @logger = logger
      @scope = scope
      @schedule = schedule
      @worker_count = 3
      @queue = Queue.new
      @script_monitor = TimelineScriptMonitor.new(name: @timeline_name, logger: @logger, scope: @scope)
      @script_monitor_thread = nil
      @thread_pool = generate_thread_pool()
      @cancel_thread = false
      @expire = 0
    end

    def generate_thread_pool
      thread_pool = []
      @worker_count.times {
        worker = TimelineWorker.new(name: @timeline_name, logger: @logger, scope: @scope, queue: @queue, script_monitor: @script_monitor)
        thread_pool << Thread.new { worker.run }
      }
      return thread_pool
    end

    def run
      @logger.info "#{@timeline_name} timeline manager running"
      @script_monitor_thread = Thread.new { @script_monitor.run }
      loop do
        start = Time.now.to_f
        @schedule.activities.each do |activity|
          start_difference = activity.start - start
          if start_difference <= 0 && !executed?(activity) && @schedule.not_queued?(activity)
            @logger.debug "#{@timeline_name} #{@scope} current start: #{start}, vs #{activity.start}, #{start_difference}"
            activity.add_event(status: 'queued')
            @queue << activity
          end
        end
        if start >= @expire
          @queue << add_expire_activity()
          request_update(start: start)
        end
        break if @cancel_thread

        sleep(1)
        break if @cancel_thread
      end
      @logger.info "#{@timeline_name} timeline manager exiting"
    end

    # An activity which has a committed event has already been run
    def executed?(activity)
      activity.fulfillment || activity.events.any? { |event| event['commit'] }
    end

    # Add task to remove events older than 7 days
    def add_expire_activity
      now = Time.now.to_f
      @expire = now + 3540 # Needs to be less than 3600 which is the hour we store in memory
      activity = ActivityModel.new(
        name: @timeline_name,
        scope: @scope,
        start: 0,
        stop: (now - (86_400 * 7)),
        kind: 'expire',
        data: {}
      )
      return activity
    end

    # This can feedback to ensure the schedule will not run out so this should fire once an
    # hour to make sure the TimelineMicroservice will collect the next hour and update the
    # schedule.
    def request_update(start:)
      notification = {
        'data' => JSON.generate({ 'time' => start }, allow_nan: true),
        'kind' => 'refresh',
        'type' => 'timeline',
        'timeline' => @timeline_name
      }
      begin
        TimelineTopic.write_activity(notification, scope: @scope)
      rescue StandardError
        @logger.error "#{@name} manager failed to request update"
      end
    end

    def shutdown
      @cancel_thread = true
      @script_monitor.shutdown
      @worker_count.times {
        @queue << nil
      }
    end
  end

  # The timeline microservice starts a manager then gets the activities
  # from the sorted set in redis and updates the schedule for the
  # manager. Timeline will then wait for an update on the timeline
  # stream this will trigger an update again to the schedule.
  class TimelineMicroservice < Microservice
    def initialize(name)
      super(name)
      @timeline_name = name.split('__')[2]
      @schedule = Schedule.new(@timeline_name)
      @manager = TimelineManager.new(name: @timeline_name, logger: @logger, scope: @scope, schedule: @schedule)
      @manager_thread = nil
      @read_topic = true
    end

    def run
      @logger.info "#{@name} timeline running"
      @manager_thread = Thread.new { @manager.run }
      loop do
        current_activities = ActivityModel.activities(name: @timeline_name, scope: @scope)
        @schedule.update(current_activities)
        break if @cancel_thread

        block_for_updates()
        break if @cancel_thread
      end
      @logger.info "#{@name} timeline exiting"
    end

    def topic_lookup_functions
      {
        'timeline' => {
          'created' => :timeline_noop,
          'refresh' => :schedule_refresh,
          'updated' => :timeline_noop,
          'deleted' => :timeline_noop
        },
        'activity' => {
          'event' => :timeline_noop,
          'created' => :create_activity_from_event,
          'updated' => :schedule_refresh,
          'deleted' => :remove_activity_from_event
        }
      }
    end

    def block_for_updates
      @read_topic = true
      while @read_topic
        begin
          TimelineTopic.read_topics(@topics) do |_topic, _msg_id, msg_hash, _redis|
            if msg_hash['timeline'] == @timeline_name
              data = JSON.parse(msg_hash['data'], allow_nan: true, create_additions: true)
              public_send(topic_lookup_functions[msg_hash['type']][msg_hash['kind']], data)
            end
          end
        rescue StandardError => e
          @logger.error "#{@timeline_name} failed to read topics #{@topics}\n#{e.formatted}"
        end
      end
    end

    def timeline_noop(data)
      @logger.debug "#{@name} timeline web socket event: #{data}"
    end

    def schedule_refresh(data)
      @logger.debug "#{@name} timeline web socket schedule refresh: #{data}"
      @read_topic = false
    end

    # Add the activity to the schedule. We don't need to hold the job in memory
    # if it is longer than an hour away. A refresh task will update that.
    def create_activity_from_event(data)
      # Recurring activities only notify once for the whole series so reload them all
      if data['recurring'] and data['recurring']['uuid']
        return schedule_refresh(data)
      end
      diff = data['start'] - Time.now.to_f
      return if diff < 0 or diff > 3600

      activity = ActivityModel.from_json(data, name: @timeline_name, scope: @scope)
      @schedule.add_activity(activity)
    end

    # Remove the activity from the schedule. We don't need to remove the activity
    # if it is longer than an hour away. It will be removed from the data.
    # Deleting a recurring series or a range only notifies once so the schedule
    # is also reloaded to drop every removed activity.
    def remove_activity_from_event(data)
      @schedule.remove_activity(data)
      schedule_refresh(data)
    end

    def shutdown
      @manager.shutdown
      # super also sets @cancel_thread = true but we want to set it first
      # so when we set @read_topic = false the run loop stops
      @cancel_thread = true
      @read_topic = false
      super()
    end
  end
end

OpenC3::TimelineMicroservice.run if __FILE__ == $0

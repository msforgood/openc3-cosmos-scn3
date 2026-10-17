#!/usr/bin/env ruby
# Run inside the OpenC3 operator container through scenario4_demo.sh.

require 'json'
require 'redis'
require 'openc3'
require 'openc3/utilities/target_file'
require 'openc3/models/cvt_model'
require 'socket'

class Scenario4Demo
  SCOPE = 'DEFAULT'
  TIMELINE = 'GROUND_OPS'
  KEY = "#{SCOPE}__openc3_timelines__#{TIMELINE}"
  STREAM = "#{SCOPE}__openc3_timelines"
  SOURCE_DOWNLINK = 'INST/procedures/downlink_msg.py'
  ORIGINAL_PATH = %r{\AINST/procedures/INST_\d{8}_\d{6}\.py\z}
  UUID = /\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/

  def initialize
    @redis = Redis.new(
      host: ENV.fetch('OPENC3_REDIS_HOSTNAME'),
      port: ENV.fetch('OPENC3_REDIS_PORT'),
      username: ENV.fetch('OPENC3_REDIS_USERNAME'),
      password: ENV.fetch('OPENC3_REDIS_PASSWORD')
    )
  end

  def run(command, uuid)
    case command
    when 'connect' then connect
    when 'reset' then reset
    when 'list' then list
    when 'show' then show(uuid)
    when 'prepare' then prepare(uuid)
    when 'switch' then switch(uuid)
    when 'notify' then notify(uuid)
    when 'result' then result(uuid)
    else
      puts 'Usage: scenario4_demo.sh connect|reset|list|show UUID|prepare UUID|switch UUID|notify UUID|result UUID'
      raise ArgumentError, "unknown command #{command.inspect}" unless command.nil? || command == 'help'
    end
  end

  private

  def ephemeral
    @ephemeral ||= Redis.new(
      host: ENV.fetch('OPENC3_REDIS_EPHEMERAL_HOSTNAME'),
      port: ENV.fetch('OPENC3_REDIS_EPHEMERAL_PORT'),
      username: ENV.fetch('OPENC3_REDIS_USERNAME'),
      password: ENV.fetch('OPENC3_REDIS_PASSWORD')
    )
  end

  def connect
    puts "Operator container: #{Socket.gethostname}"
    puts "Redis credentials: username from OPENC3_REDIS_USERNAME; password from OPENC3_REDIS_PASSWORD (not displayed)"
    main_ping = @redis.ping
    raise "main Redis PING failed: #{main_ping.inspect}" unless main_ping.to_s.upcase == 'PONG'
    puts "Main Redis: #{ENV.fetch('OPENC3_REDIS_HOSTNAME')}:#{ENV.fetch('OPENC3_REDIS_PORT')}  PONG"
    ephemeral_ping = ephemeral.ping
    raise "ephemeral Redis PING failed: #{ephemeral_ping.inspect}" unless ephemeral_ping.to_s.upcase == 'PONG'
    puts "Ephemeral Redis: #{ENV.fetch('OPENC3_REDIS_EPHEMERAL_HOSTNAME')}:#{ENV.fetch('OPENC3_REDIS_EPHEMERAL_PORT')}  PONG"
    puts "Timeline key: #{KEY}  #{key_state}"
    puts "Notification stream: #{STREAM}"
    puts 'Next: scenario4_demo.sh list'
  end

  def key_state
    type = @redis.type(KEY)
    case type
    when 'none' then 'ABSENT  reservations=0'
    when 'zset' then "PRESENT  reservations=#{@redis.zcard(KEY)}"
    else raise "unexpected Redis type for #{KEY}: #{type}"
    end
  end

  def reset
    @redis.watch(KEY)
    begin
      snapshot = @redis.zrange(KEY, 0, -1)
      activities = snapshot.map { |raw| JSON.parse(raw) }
      busy = activities.find do |activity|
        %w[queued started running waiting paused breakpoint].include?(activity.fetch('events', []).last&.fetch('event', nil))
      end
      raise "activity #{busy['uuid']} is queued or running; wait until it completes" if busy
      transaction = @redis.multi { |multi| multi.del(KEY) }
    ensure
      @redis.unwatch
    end
    raise 'the Timeline key changed during reset; retry after checking list' unless
      transaction.is_a?(Array) && transaction.length == 1 && [0, 1].include?(transaction.first)
    deleted = transaction.first
    refresh_id = ephemeral.xadd(STREAM, {
      'timeline' => TIMELINE, 'kind' => 'refresh', 'type' => 'timeline',
      'data' => JSON.generate({ 'time' => Time.now.to_f })
    })
    raise 'Timeline key was deleted, but the refresh notification failed; run reset again' if refresh_id.to_s.empty?
    puts "RESET: #{KEY}  deleted=#{deleted}  previous_reservations=#{activities.length}"
    puts "Timeline refresh: #{refresh_id}"
    puts "Timeline key after reset: #{key_state}"
    puts 'Next: scenario4_demo.sh list'
  end

  def records
    @redis.zrange(KEY, 0, -1).map { |raw| [raw, JSON.parse(raw)] }
  end

  def record(uuid)
    raise ArgumentError, 'supply the Calendar reservation UUID' unless UUID.match?(uuid.to_s)
    found = records.select { |_raw, activity| activity['uuid'] == uuid }
    raise "expected one GROUND_OPS reservation for #{uuid}; found #{found.length}" unless found.length == 1

    raw, activity = found.first
    raise 'reservation is not a DEFAULT GROUND_OPS script' unless
      activity['scope'] == SCOPE && activity['name'] == TIMELINE && activity['kind'] == 'script' &&
      activity['data'].is_a?(Hash) && activity['events'].is_a?(Array)
    [raw, activity]
  end

  def paths(activity, uuid)
    current = activity.fetch('data').fetch('script')
    suffix = "_downlink_#{uuid.delete('-')}.py"
    original = if ORIGINAL_PATH.match?(current)
                 current
               elsif current.end_with?(suffix)
                 current.delete_suffix(suffix) + '.py'
               end
    raise "unexpected script path #{current.inspect}" unless original && ORIGINAL_PATH.match?(original)
    [original, original.sub(/\.py\z/, suffix), current]
  end

  def pending!(activity, minimum_seconds: 120)
    start = activity['start']
    raise 'reservation start time is invalid' unless start.is_a?(Numeric)
    raise 'reservation has already executed' if
      activity['fulfillment'] == true || activity['events'].any? { |event| event['commit'] == true }
    remaining = start - Time.now.to_f
    raise "only #{remaining.round}s remain; create a fresh Runner 04 reservation" unless remaining > minimum_seconds
  end

  def body(path)
    OpenC3::TargetFile.body(SCOPE, path)
  end

  def expected_body(original)
    routine = body(original)
    downlink = body(SOURCE_DOWNLINK)
    raise "missing source script #{original}" if routine.nil?
    raise "missing installed script #{SOURCE_DOWNLINK}" if downlink.nil?
    raise 'installed downlink procedure lacks the TC' unless downlink.include?('cmd("INST DOWNLINK_MSG")')
    routine.rstrip + "\n\n# Scenario 4 demo: additional downlink procedure\n" + downlink
  end

  def list
    puts "Timeline key: #{KEY}  #{key_state}"
    items = records.map(&:last).select { |item| item['name'] == TIMELINE && item['kind'] == 'script' }
    items = items.sort_by { |item| item['start'].to_f }.last(30)
    puts "GROUND_OPS script reservations (newest #{items.length}):"
    items.each do |item|
      puts "#{item['uuid']}  #{Time.at(item['start']).getlocal('+09:00')}  " \
           "fulfilled=#{item['fulfillment']}  #{item.dig('data', 'script')}"
    end
    puts 'Run: scenario4_demo.sh show UUID' unless items.empty?
  end

  def show(uuid)
    _raw, activity = record(uuid)
    original, replacement, current = paths(activity, uuid)
    puts "UUID: #{uuid}"
    puts "Start (KST): #{Time.at(activity['start']).getlocal('+09:00')}"
    puts "Seconds remaining: #{(activity['start'] - Time.now.to_f).round}"
    puts "Current script: #{current}"
    puts "Original script: #{original}"
    puts "Replacement script: #{replacement}"
    puts "Fulfilled: #{activity['fulfillment']}"
    source = body(current)
    raise "script file missing: #{current}" if source.nil?
    puts "--- #{current} ---"
    puts source
    puts '--- end ---'
  end

  def prepare(uuid)
    _raw, activity = record(uuid)
    pending!(activity)
    original, replacement, current = paths(activity, uuid)
    raise 'reservation was already switched' unless current == original
    desired = expected_body(original)
    existing = body(replacement)
    if existing.nil?
      raise 'TargetFile.create failed' unless OpenC3::TargetFile.create(SCOPE, replacement, desired)
      raise 'replacement readback mismatch' unless body(replacement) == desired
      puts 'PREPARED'
    elsif existing == desired
      puts 'ALREADY PREPARED'
    else
      raise "replacement path has different content: #{replacement}"
    end
    puts "Original: #{original}"
    puts "Replacement: #{replacement}"
    puts 'Added procedure: INST DOWNLINK_MSG, then wait for five INST MESSAGE packets'
    puts 'Next: scenario4_demo.sh switch UUID'
  end

  def switch(uuid)
    old_raw, activity = record(uuid)
    pending!(activity)
    original, replacement, current = paths(activity, uuid)
    if current == replacement
      puts "ALREADY SWITCHED: #{replacement}"
      return
    end
    raise "unexpected current path #{current}" unless current == original
    replacement_body = body(replacement)
    raise "replacement file is missing; run: scenario4_demo.sh prepare #{uuid}" if replacement_body.nil?
    raise "replacement file differs from the prepared script: #{replacement}" unless
      replacement_body == expected_body(original)

    activity['data']['script'] = replacement
    activity['updated_at'] = (Time.now.to_f * 1_000_000_000).to_i
    activity['events'] << { 'time' => Time.now.to_i, 'event' => 'updated' }
    new_raw = JSON.generate(activity)

    @redis.watch(KEY)
    begin
      live = @redis.zrangebyscore(KEY, activity['start'], activity['start']).select do |raw|
        JSON.parse(raw)['uuid'] == uuid
      end
      raise 'reservation changed while preparing the switch' unless live == [old_raw]
      raise 'new member already exists' unless @redis.zscore(KEY, new_raw).nil?
      transaction = @redis.multi do |multi|
        multi.zrem(KEY, old_raw)
        multi.zadd(KEY, activity['start'], new_raw)
      end
    ensure
      @redis.unwatch
    end
    raise "Redis switch failed: #{transaction.inspect}" unless
      transaction.is_a?(Array) && transaction.length == 2 && transaction.all? { |value| value == 1 || value == true }
    current_rows = records.select { |_raw, item| item['uuid'] == uuid }
    raise 'reservation missing or duplicated after switch' unless
      current_rows.length == 1 && current_rows.first.last.dig('data', 'script') == replacement
    puts "SWITCHED: #{original} -> #{replacement}"
    puts "Same UUID and start: #{uuid} at #{Time.at(activity['start']).getlocal('+09:00')}"
    puts 'Next: scenario4_demo.sh notify UUID'
  end

  def notify(uuid)
    raw, activity = record(uuid)
    pending!(activity, minimum_seconds: 0)
    _original, replacement, current = paths(activity, uuid)
    raise 'switch the reservation before notifying' unless current == replacement
    stream_id = ephemeral.xadd(STREAM, {
      'timeline' => TIMELINE, 'kind' => 'updated', 'type' => 'activity', 'data' => raw
    })
    raise 'timeline update was not published' if stream_id.to_s.empty?
    puts "NOTIFIED: #{STREAM} stream ID #{stream_id}"
    puts "Calendar script: #{current}"
    puts 'Next: refresh Calendar, then run scenario4_demo.sh result UUID after the scheduled time'
  end

  def result(uuid)
    _raw, activity = record(uuid)
    original, replacement, current = paths(activity, uuid)
    puts "UUID: #{uuid}"
    puts "Scheduled: #{Time.at(activity['start']).getlocal('+09:00')}"
    puts "Original: #{original}"
    puts "Current: #{current}"
    puts "Fulfilled: #{activity['fulfillment']}"
    puts 'Events:'
    activity['events'].each do |event|
      puts "  #{Time.at(event['time']).getlocal('+09:00')} #{event['event']} #{event['message']}"
    end
    started = activity['events'].reverse.find do |event|
      event['event'] == 'started' && event['message'].to_s.start_with?("#{replacement} => ")
    end
    unless started
      puts 'Execution: replacement script has not started yet'
      return
    end
    script_id = started['message'].split('=>', 2).last.to_s.strip
    status_raw = @redis.hget("running-script-completed__#{SCOPE}", script_id) ||
                 @redis.hget("running-script__#{SCOPE}", script_id)
    if status_raw
      status = JSON.parse(status_raw)
      puts "Script Runner: id=#{script_id} state=#{status['state']} errors=#{status['errors'].inspect}"
      if status['log']
        puts "Script log: #{status['log']}"
        if status['state'] == 'completed' && status['log'].start_with?("#{SCOPE}/tool_logs/sr/")
          begin
            log = OpenC3::Bucket.getClient.get_object(
              bucket: ENV.fetch('OPENC3_LOGS_BUCKET'), key: status['log']
            ).body.read
            proof_lines = log.lines.grep(/HK received:|\[[1-5]\/5\]|Downlink complete|ERROR/i)
            puts 'Script output:'
            proof_lines.last(10).each { |line| puts "  #{line.rstrip}" }
          rescue StandardError => error
            puts "Script log could not be read yet: #{error.class}: #{error.message}"
          end
        end
      end
    else
      puts "Script Runner: id=#{script_id}; status not found in Redis"
    end
    begin
      count = OpenC3::CvtModel.get_item('INST', 'MESSAGE', 'RECEIVED_COUNT', type: :CONVERTED, scope: SCOPE)
      seq = OpenC3::CvtModel.get_item('INST', 'MESSAGE', 'SEQ', type: :CONVERTED, scope: SCOPE)
      text = OpenC3::CvtModel.get_item('INST', 'MESSAGE', 'TEXT', type: :CONVERTED, scope: SCOPE)
      puts "Latest INST MESSAGE: received_count=#{count} seq=#{seq} text=#{text}"
    rescue StandardError => error
      puts "Latest INST MESSAGE unavailable: #{error.class}: #{error.message}"
    end
    puts 'Confirm all five MESSAGE frames above or in Script Runner > Completed Scripts > Log.'
  end
end

begin
  command, uuid, extra = ARGV
  raise ArgumentError, 'too many arguments' if extra
  Scenario4Demo.new.run(command, uuid)
rescue StandardError => error
  warn "ERROR: #{error.message}"
  exit 1
end

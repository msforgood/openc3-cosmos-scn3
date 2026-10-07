require 'timeout'

module ScenarioBootstrap
  class Failure < StandardError; end

  # Keep subprocess diagnostics (which can contain credentials) out of Compose logs.
  # Kill the process group on timeout, including gem-install child processes.
  def self.run_process(argv, seconds:, env: {}, termination_grace: 0)
    pid = Process.spawn(env, *argv, in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true)
    begin
      _, status = Timeout.timeout(seconds) { Process.wait2(pid) }
      raise Failure, 'Child process failed; no credentials or child output were logged' unless status.success?
    rescue Timeout::Error
      raise Failure, 'Child process exceeded its time limit'
    ensure
      # Let a supervised Ruby installer unwind its own child-process ensure
      # before killing the group. All child output remains suppressed.
      begin
        Process.kill('TERM', -pid)
        sleep termination_grace if termination_grace.positive?
      rescue Errno::ESRCH
        # Already exited.
      end
      begin
        Process.kill('KILL', -pid)
      rescue Errno::ESRCH
        # Already exited.
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        # Already reaped.
      end
    end
  end
end

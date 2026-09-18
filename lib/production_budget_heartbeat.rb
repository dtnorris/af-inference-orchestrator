# frozen_string_literal: true

require "thread"

class ProductionBudgetHeartbeat
  attr_reader :last_error

  def initialize(client:, budget_id:, plan_sha256:, interval_seconds:)
    @client = client
    @budget_id = budget_id.to_s
    @plan_sha256 = plan_sha256.to_s
    @interval_seconds = Float(interval_seconds)
    raise ArgumentError, "heartbeat interval must be positive" unless @interval_seconds.positive?

    @mutex = Mutex.new
    @condition = ConditionVariable.new
    @running = false
    @thread = nil
    @last_error = nil
  end

  def start
    # Establish the AFIO side of the heartbeat contract synchronously before
    # any paid work is allowed to proceed. Later transient failures are left
    # to the independent guardian's stale-heartbeat fail-closed policy.
    send_heartbeat!
    @mutex.synchronize do
      return self if @running
      @running = true
    end
    @thread = Thread.new { heartbeat_loop }
    self
  end

  def stop
    thread = nil
    @mutex.synchronize do
      @running = false
      @condition.broadcast
      thread = @thread
    end
    thread&.join
    self
  end

  private

  def heartbeat_loop
    while wait_interval
      begin
        send_heartbeat!
        @mutex.synchronize { @last_error = nil }
      rescue StandardError => e
        @mutex.synchronize { @last_error = e }
      end
    end
  end

  def send_heartbeat!
    @client.heartbeat_budget(
      budget_id: @budget_id,
      plan_sha256: @plan_sha256
    )
  end

  def wait_interval
    @mutex.synchronize do
      return false unless @running
      @condition.wait(@mutex, @interval_seconds)
      @running
    end
  end
end

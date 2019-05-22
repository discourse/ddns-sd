# frozen_string_literal: true
require 'docker-api'

require 'ddnssd/container'

module DDNSSD
  class DockerWatcher
    # Raise this exception in the thread to signal termination
    class Terminate < Exception; end

    def initialize(queue:, config:)
      @queue, @config = queue, config

      @docker_host = @config.docker_host
      @logger = @config.logger

      @event_count = @config.metrics_registry.counter(:ddnssd_docker_event_total, "How many docker events we have seen and processed")
      @event_count.increment({ type: "ignored" }, 0)
      @event_count.increment({ type: "started" }, 0)
      @event_count.increment({ type: "stopped" }, 0)

      @event_errors = @config.metrics_registry.counter(:ddnssd_docker_event_exceptions_total, "How many exceptions have been raised for handling docker events")

      @op_mutex = Mutex.new
    end

    def run
      @last_event_time = Time.now.to_i
      @conn = Docker::Connection.new(@docker_host, read_timeout: 3600)

      begin
        loop { process_events }
      rescue Docker::Error::TimeoutError
        retry
      rescue Excon::Error::Socket => ex
        @logger.debug(progname) { (["Got socket error while listening for events: #{ex.message} (#{ex.class})"] + ex.backtrace).join("\n  ") }
        sleep 1
        retry
      rescue DDNSSD::DockerWatcher::Terminate
        return
      rescue StandardError => ex
        @event_errors.increment(class: ex.class.to_s)

        @logger.error(progname) { (["#{ex.message} (#{ex.class})"] + ex.backtrace).join("\n  ") }
        sleep 1
        retry
      end
    rescue StandardError => ex
      @logger.error(progname) { (["Fatal error: #{ex.message} (#{ex.class}).  Terminating."] + ex.backtrace).join("\n  ") }
      @queue.push [:terminate]
    end

    # Async stuff is a right shit to test, and frankly the sorts of bugs that
    # crop up in this stuff are the sort of concurrency shitshows that don't
    # reliably get found by testing anyway.  So...
    #:nocov:
    def run!
      @op_mutex.synchronize do
        return if @runner_thread

        @runner_thread = Thread.new { self.run }
      end
    end

    def shutdown
      @op_mutex.synchronize do
        return if @runner_thread.nil?

        @runner_thread.raise(DDNSSD::DockerWatcher::Terminate)
        @runner_thread.join
        @runner_thread = nil
      end
    end
    #:nocov:

    private

    def progname
      @logger_progname ||= "DDNSSD::DockerWatcher(#{@docker_host.inspect})"
    end

    def process_events
      @logger.debug(progname) { "Asking for events since #{@last_event_time}" }
      pe_start = Time.now.to_f

      Docker::Event.since(@last_event_time, {}, @conn) do |event|
        @last_event_time = event.time

        @logger.debug(progname) { "#{pe_start}: Docker event@#{event.timeNano}: #{event.Type}.#{event.Action} on #{event.ID}" }

        next unless event.Type == "container"

        queue_item = if event.Action == "start"
          @event_count.increment(type: "started")
          [:started, event.ID]
        elsif event.Action == "kill"
          [:stopped, event.ID]
        elsif event.Action == "die"
          @event_count.increment(type: "stopped")
          [:died, event.ID, event.Actor.Attributes["exitCode"].to_i]
        else
          @event_count.increment(type: "ignored")
          nil
        end

        next if queue_item.nil? || queue_item.last.nil?

        @queue.push(queue_item)
      end
    end
  end
end

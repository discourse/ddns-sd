require 'frankenstein/server'
require 'logger'
require 'ipaddr'

require 'ddnssd/config'
require 'ddnssd/docker_watcher'

module DDNSSD
  class System
    attr_reader :config

    # Create a new DDNS-SD system.
    #
    # @param env [Hash] the set of environment variables
    #   with which to configure the system.
    #
    # @param logger [Logger] pass in a custom logger to the system.
    #
    # @return [DDNSSD::System]
    #
    # @raise [DDNSSD::Config::InvalidEnvironmentError] if any problems are
    #   detected with the environment variables found.
    #
    def initialize(env, logger:)
      @config     = DDNSSD::Config.new(env, logger: logger)
      @logger     = logger
      @backends   = @config.backend_classes.map { |klass| klass.new(@config) }
      @queue      = Queue.new
      @watcher    = DDNSSD::DockerWatcher.new(queue: @queue, config: @config)
      @containers = {}
    end

    def run
      @watcher.run!

      if @config.enable_metrics
        @logger.info(progname) { "Starting metrics server" }
        register_start_time_metric
        @metrics_server = Frankenstein::Server.new(port: 9218, logger: @logger, registry: @config.metrics_registry)
        @metrics_server.run
      end

      @backends.each { |backend| reconcile_containers(backend) }

      if @config.host_dns_record
        @backends.each { |backend| backend.publish_record(@config.host_dns_record) }
      end

      loop do
        if @queue.empty?
          @backends.each { |backend| backend.rest }
        end

        item = @queue.pop
        @logger.debug(progname) { "Received message #{item.inspect}" }

        case (item.first rescue nil)
        when :started
          docker_container = begin
            Docker::Container.get(item.last, {}, docker_connection)
          rescue Docker::Error::NotFoundError
            # container was destroyed before we processed this message
            @logger.warn(progname) { "Docker says container #{item.last} does not exist. Ignoring :started message." }
            nil
          end

          if docker_container
            if @containers[item.last]&.crashed
              @logger.warn(progname) { "Container #{item.last} that didn't stop cleanly has restarted. Recreating its records." }
              @backends.each { |backend| @containers[item.last].suppress_records(backend) }
            end
            @containers[item.last] = DDNSSD::Container.new(docker_container, @config, self)
            @backends.each { |backend| @containers[item.last].publish_records(backend) }
          end
        when :stopped
          @containers[item.last].stopped = true if @containers[item.last]
        when :died
          _, id, exitcode = item
          unless @containers[id]
            @logger.warn(progname) { "Container #{id} died, but we're not tracking it. Ignoring :died message." }
            next
          end

          if exitcode == 0 || @containers[id].stopped
            @backends.each { |backend| @containers[id].suppress_records(backend) }
            @containers.delete(id)
          else
            @containers[id].crashed = true
            @logger.warn(progname) { "Container #{id} did not stop cleanly (exitcode #{exitcode}); not suppressing records" }
          end
        when :suppress_all
          @logger.info(progname) { "Withdrawing all DNS records..." }
          @backends.each do |backend|
            @logger.debug(progname) { "Withdrawing records from #{backend.name}" }
            @containers.values.each do |c|
              @logger.debug(progname) { "Withdrawing records for container #{c.id}" }
              c.suppress_records(backend)
            end
          end
          @logger.debug(progname) { "Suppressing common records" }
          @backends.each(&:suppress_shared_records)
          @logger.info(progname) { "Withdrawal complete." }
        when :terminate
          @logger.info(progname) { "Terminating." }
          break
        else
          @logger.error(progname) { "SHOULDN'T HAPPEN: docker watcher sent an unrecognized message: #{item.inspect}.  This is a bug, please report it." }
        end
      end
    end

    def shutdown(suppress_records = true)
      @logger.debug(progname) { "Received shutdown request, suppress_records = #{suppress_records.inspect}" }

      @queue.push([:suppress_all]) if suppress_records
      @queue.push([:terminate])
      @watcher.shutdown
      @metrics_server.shutdown if @metrics_server
    end

    def container(id)
      begin
        DDNSSD::Container.new(Docker::Container.get(id, {}, docker_connection), @config, self)
      rescue Docker::Error::NotFoundError
        nil
      end
    end

    private

    def progname
      "DDNSSD::System"
    end

    def reconcile_containers(backend)
      @logger.info(progname) { "Reconciling DNS records in #{backend.name} with container services" }

      populate_container_cache

      containers = @containers.values

      our_live_records = backend.dns_records.select { |rr| our_record?(rr) }
      our_desired_records = containers.map { |c| c.dns_records }.flatten(1)

      @logger.info(progname) { "Found #{our_live_records.length} relevant DNS records." }
      @logger.debug(progname) { (["Relevant DNS records:"] + our_live_records.map { |rr| "#{rr.name} #{rr.ttl} #{rr.type} #{rr.value}" }).join("\n  ") } unless our_live_records.empty?
      @logger.info(progname) { "Should have #{our_desired_records.length} DNS records." }
      @logger.debug(progname) { (["Desired DNS records:"] + our_desired_records.map { |rr| "#{rr.name} #{rr.ttl} #{rr.type} #{rr.value}" }).join("\n  ") } unless our_desired_records.empty?

      # Delete any of "our" records that are no longer needed
      @logger.info(progname) { "Deleting #{(our_live_records - our_desired_records).length} DNS records." }
      (our_live_records - our_desired_records).each { |rr| backend.suppress_record(rr) }

      # ... and create any new records we need
      @logger.info(progname) { "Creating #{(our_desired_records - our_live_records).uniq.length} DNS records." }
      (our_desired_records - our_live_records).uniq.each { |rr| backend.publish_record(rr) }
    end

    def our_record?(rr)
      suffix = /#{Regexp.escape(@config.hostname)}\z/

      case rr.data
      when Resolv::DNS::Resource::IN::A, Resolv::DNS::Resource::IN::AAAA
        rr.name =~ suffix
      when Resolv::DNS::Resource::IN::SRV
        rr.data.target.to_s =~ suffix
      when Resolv::DNS::Resource::IN::PTR, Resolv::DNS::Resource::IN::TXT
        # Everyone shares ownership of TXT and PTR records.  By saying we
        # don't "own" any particular DNS record, we won't delete it, but
        # will re-create it on start.  This is OK by me.
        false
      else
        # Mystery record types are best not claimed.
        false
      end
    end

    def populate_container_cache
      @containers = {}

      # Docker's `.all` method returns wildly different data in each
      # container's `.info` structure to what `.get` returns (the API endpoints
      # have completely different schemas), and the `.all` response is missing
      # something things we rather want, so to get everything we need, this
      # individual enumeration is unfortunately necessary -- and, of course,
      # because a container can cease to exist between when we get the list and
      # when we request it again, it all gets far more complicated than it
      # should need to be.
      #
      # Thanks, Docker!
      Docker::Container.all({}, docker_connection).each { |c| @containers[c.id] = container(c.id) }
      @containers.delete_if { |k, v| v.nil? }
    end

    def docker_connection
      @docker_connection ||= Docker::Connection.new(@config.docker_host, {})
    end

    def register_start_time_metric
      #:nocov:
      label_set = if ENV["DDNSSD_GIT_REVISION"]
        { git_revision: ENV["DDNSSD_GIT_REVISION"] }
      else
        {}
      end

      @config.metrics_registry.gauge(:ddnssd_start_timestamp, "When the server was started").set(label_set, Time.now.to_i)
      #:nocov:
    end
  end
end

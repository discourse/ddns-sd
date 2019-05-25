require 'ddnssd/service_instance'

module DDNSSD
  class Container
    attr_reader :id, :name, :ipv4_address, :ipv6_address, :host_network

    attr_accessor :stopped, :crashed

    def initialize(docker_data, system_config, system)
      @id = docker_data.id

      @config = system_config
      @system = system
      @logger = @config.logger

      @name = (docker_data.info["Name"] || docker_data.info["Names"].first).sub(/\A\//, '')

      @service_instances = parse_service_instances(docker_data.info["Config"]["Labels"])

      host_config = docker_data.info["HostConfig"]
      @host_network = !!(host_config && (host_config["NetworkMode"]&.downcase == "host"))

      if @host_network
        @ipv4_address = nil
        @ipv6_address = nil
      elsif root_id = docker_data.info["Config"]["Labels"]["org.hezmatt.moby-derp.root-container-id"]
        @logger.info(progname) { "Using #{root_id} as source of network address information" }
        if @id == root_id
          #:nocov:
          raise InvalidContainerError,
                "root-container-id (#{@id.inspect}) points to us!"
          #:nocov:
        end
        root_container = system.container(root_id)
        @ipv4_address = root_container.ipv4_address
        @ipv6_address = root_container.ipv6_address
      else
        @ipv4_address = docker_data.info["NetworkSettings"]["IPAddress"]
        @ipv6_address = docker_data.info["NetworkSettings"]["GlobalIPv6Address"]
      end

      @exposed_ports   = docker_data.info["Config"]["ExposedPorts"] || {}
      @published_ports = docker_data.info["NetworkSettings"]["Ports"]

      @logger.debug(progname) { "IPv4 address: #{@ipv4_address.inspect}" }
      @logger.debug(progname) { "IPv6 address: #{@ipv6_address.inspect}" }
      @logger.debug(progname) { "Exposed ports: #{@exposed_ports.inspect}" }
      @logger.debug(progname) { "Published ports: #{@published_ports.inspect}" }
    end

    def short_id
      @id[0..11]
    end

    def dns_records
      @service_instances.map { |si| si.dns_records }.flatten(1)
    end

    def port_exposed?(spec)
      @host_network || !@exposed_ports[spec].nil?
    end

    def addressable?
      @host_network || (!@ipv4_address.nil? && @ipv4_address != "") || (!@ipv6_address.nil? && @ipv6_address != "")
    end

    def host_port_for(spec)
      if @host_network
        spec.split("/")[0].to_i
      else
        (@published_ports[spec].first["HostPort"] rescue nil).tap do |v|
          @logger.debug(progname) { "host_port_for(#{spec.inspect}) => #{v.inspect}" }
        end
      end
    end

    def host_address_for(spec)
      addr = @published_ports[spec].first["HostIp"] rescue nil

      if addr == "0.0.0.0" || addr == ""
        nil
      else
        addr
      end.tap do |v|
        @logger.debug(progname) { "host_address_for(#{spec.inspect}) => #{v.inspect}" }
      end
    end

    def publish_records(backend)
      dns_records.each { |rr| backend.publish_record(rr) }
    end

    def suppress_records(backend)
      dns_records.each { |rr| backend.suppress_record(rr) unless %i{TXT PTR}.include?(rr.type) }
    end

    private

    def progname
      @logger_progname ||= "DDNSSD::Container(#{short_id})"
    end

    def parse_service_instances(labels)
      labels.select do |lbl, val|
        lbl =~ /\Aorg\.discourse\.service\./
      end.map do |lbl, val|
        [lbl.sub(/\Aorg\.discourse\.service\./, ''), val]
      end.each_with_object(Hash.new { |h, k| h[k] = {} }) do |(lbl, val), h|
        if lbl =~ /\A_([^.]+(?:\.\d+)?)\.(.*)\z/
          h[$1][$2] = val
        else
          @logger.warn(progname) { "Ignoring invalid label org.discourse.service.#{lbl}." }
        end
      end.map do |svc, lbls|
        # Strip off any numeric suffix
        svcname = svc.split('.', 2).first
        DDNSSD::ServiceInstance.new(svcname, lbls, self, @config)
      end.compact
    end
  end
end

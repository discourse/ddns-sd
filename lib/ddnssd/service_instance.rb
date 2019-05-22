# frozen_string_literal: true
require 'resolv'

require 'ddnssd/dns_record'
require 'ddnssd/error'

module DDNSSD
  class ServiceInstance
    class ServiceInstanceValidationError < DDNSSD::Error; end

    def initialize(name, labels, container, config)
      @name, @labels, @container, @config = name, labels, container, config

      @logger = @config.logger
    end

    # Returns DNS records with relative (partially-qualified) names.
    # Backends are reponsible for creating fully-qualified names.
    def dns_records
      unless @container.addressable?
        @logger.debug(progname) { "Container #{@container.name} does not have IP addresses; not creating DNS records for service #{@name}" }
        return []
      end

      begin
        protos.each do |proto|
          unless @container.port_exposed?("#{@labels["port"]}/#{proto}")
            if @config.validate_ports
              raise ServiceInstanceValidationError,
                "Port specified in labels (#{@labels["port"]}/#{proto}) on container #{container_desc} not exposed."
            else
              @logger.warn(progname) { "Port specified in labels (#{@labels["port"]}/#{proto}) on container #{container_desc} not exposed." }
            end
          end
        end

        # This ordering is quite particular; it makes sure that records
        # which reference other records are created after the referenced
        # records.  That's not *essential*, but it is polite.
        a_records + aaaa_records + srv_records + txt_records + ptr_records + cname_records
      rescue ServiceInstanceValidationError => ex
        @logger.error(progname) { "#{ex.message} Service not registered." }
        return []
      end
    end

    private

    def progname
      @logger_progname ||= "DDNSSD::ServiceInstance(#{@name})"
    end

    def container_desc
      "#{@container.short_id} (#{@container.name.inspect})"
    end

    def host_rdn
      @config.hostname
    end

    def container_rdn
      "#{@container.short_id}.#{host_rdn}"
    end

    def address_rdn
      "#{instance_v4_address.gsub('.', '-')}.#{host_rdn}"
    end

    def instance_address_rdn
      if @container.host_network
        host_rdn
      elsif @container.host_port_for("#{@labels["port"]}/#{protos.first}")
        if @container.host_address_for("#{@labels["port"]}/#{protos.first}")
          address_rdn
        else
          host_rdn
        end
      else
        container_rdn
      end
    end

    def service_rdn(proto)
      "_#{@name}._#{proto}"
    end

    def instance_v4_address
      if @container.host_port_for("#{@labels["port"]}/#{protos.first}")
        if pub_addr = @container.host_address_for("#{@labels["port"]}/#{protos.first}")
          pub_addr
        else
          if @config.host_ip_address.nil?
            raise ServiceInstanceValidationError,
              "Published port on default IP address detected on container #{container_desc}, but no host IP address configured."
          end

          nil
        end
      else
        @container.ipv4_address
      end
    end

    def srv_instance_rdn(proto)
      name = (@labels["instance"] || @container.name).dup
      name.force_encoding("UTF-8")

      if name.bytesize == 0
        raise ServiceInstanceValidationError,
          "Instance name on container #{container_desc} is empty."
      end

      if name.bytesize > 63
        raise ServiceInstanceValidationError,
          "Instance name #{name.inspect} on container #{container_desc} is too long (must be <= 63 octets)."
      end

      unless name.valid_encoding?
        raise ServiceInstanceValidationError,
          "Instance name #{name.inspect} on container #{container_desc} is not valid UTF-8."
      end

      unless name =~ /\A[^\u0000-\u001f\u007f]+\z/
        raise ServiceInstanceValidationError,
          "Instance name #{name.inspect} on container #{container_desc} is not valid Net-Unicode (contains ASCII control characters)."
      end

      "#{name}.#{service_rdn(proto)}"
    end

    def protos
      unless @labels["protocol"].nil? || @labels["protocol"] =~ /\A(|tcp|udp|both)\z/i
        raise ServiceInstanceValidationError,
          "Invalid protocol label #{@labels["protocol"].inspect} on container #{container_desc}, must be one of 'tcp', 'udp', or 'both'."
      end

      case @labels["protocol"].to_s.downcase
      when "", "tcp"
        ["tcp"]
      when "udp"
        ["udp"]
      when "both"
        ["tcp", "udp"]
      end
    end

    def a_records
      if !@config.ipv6_only && !@container.host_network && instance_v4_address
        [DDNSSD::DNSRecord.new(instance_address_rdn, @config.record_ttl, :A, instance_v4_address)]
      else
        []
      end
    end

    def aaaa_records
      if  @container.host_network ||
          @container.host_port_for("#{@labels["port"]}/#{protos.first}") ||
          @container.ipv6_address.nil? ||
          @container.ipv6_address.empty?
        []
      else

        [DDNSSD::DNSRecord.new(instance_address_rdn, @config.record_ttl, :AAAA, @container.ipv6_address)]
      end
    end

    def parse_ushort_label(k)
      if @labels[k]
        unless @labels[k] =~ /\A\d+\z/
          raise ServiceInstanceValidationError,
            "Value #{@labels[k].inspect} for label org.discourse.service._#{@name}.#{k} on #{container_desc} is not a number."
        end

        unless (0..65535).include?(@labels[k].to_i)
          raise ServiceInstanceValidationError,
            "Value #{@labels[k].inspect} for label org.discourse.service._#{@name}.#{k} on #{container_desc} is invalid (must be between 0-65535 inclusive)."
        end

        @labels[k].to_i
      else
        0
      end
    end

    def srv_records
      priority = parse_ushort_label("priority")
      weight   = parse_ushort_label("weight")

      protos.map do |proto|
        port = @container.host_port_for("#{@labels["port"]}/#{proto}") || @labels["port"]

        DDNSSD::DNSRecord.new(srv_instance_rdn(proto),
            @config.record_ttl,
            :SRV,
            priority,
            weight,
            port.to_i,
            instance_address_rdn
        )
      end
    end

    def ptr_records
      protos.map do |proto|
        DDNSSD::DNSRecord.new(service_rdn(proto), @config.record_ttl, :PTR, srv_instance_rdn(proto))
      end
    end

    def validate_tag_key(k)
      if k == ""
        raise ServiceInstanceValidationError,
          "Tag label set on #{container_desc} has an empty tag key."
      end

      if k.include?("=")
        raise ServiceInstanceValidationError,
          "Tag key #{k.inspect} on #{container_desc} contains an equals sign, which is forbidden."
      end

      unless k =~ /\A[\x20-\x7e]+\z/
        raise ServiceInstanceValidationError,
          "Tag label #{k.inspect} on #{container_desc} contains a forbidden character (only printable ASCII allowed)."
      end
    end

    def parse_tag_labels
      value_tags = @labels.select { |k, v| k =~ /\Atag\./ }.map do |k, v|
        k = k.sub(/\Atag\./, '')

        validate_tag_key(k)

        "#{k}=#{v}"
      end

      boolean_tags = @labels["tags"].to_s.split("\n").each { |t| validate_tag_key(t) }

      tags = value_tags + boolean_tags

      tags.each do |t|
        if t.bytesize > 255
          raise ServiceInstanceValidationError,
            "Tag #{t.inspect} on #{container_desc} is too long (must be <= 255 octets)."
        end
      end

      tags.sort_by! { |v| v =~ /\Atxtvers=/ ? 0 : 1 }

      if tags.empty?
        [""]
      else
        tags
      end
    end

    def txt_records
      protos.map do |proto|
        DDNSSD::DNSRecord.new(srv_instance_rdn(proto), @config.record_ttl, :TXT, *parse_tag_labels)
      end
    end

    def cname_records
      @labels["aliases"].to_s.split(',').map do |relrrname|
        DDNSSD::DNSRecord.new(relrrname, @config.record_ttl, :CNAME, instance_address_rdn)
      end
    end
  end
end

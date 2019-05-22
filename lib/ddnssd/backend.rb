# frozen_string_literal: true
require 'frankenstein/request'

require 'ddnssd/error'

module DDNSSD
  class Backend
    class InvalidRequest < DDNSSD::Error; end

    PUBLISHABLE_TYPES = [:A, :AAAA, :CNAME, :SRV, :TXT, :PTR]

    def self.backend_name
      self.to_s.split("::").last.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def initialize(config)
      @config = config
      @logger = @config.logger

      @request_stats = Frankenstein::Request.new(
        "ddnssd_backend_#{name}",
        description: "DNS backend #{name}",
        registry: @config.metrics_registry
      )

      @shared_records = {}
    end

    def name
      self.class.backend_name
    end

    def dns_records
      #:nocov:
      raise NoMethodError, "#dns_records not implemented by backend #{self.class}"
      #:nocov:
    end

    def publish_record(rr)
      @request_stats.measure(op: "publish", rrtype: rr.type.to_s) do
        @logger.debug(progname) { "Publishing record #{rr.name} #{rr.ttl} #{rr.type} #{rr.value}" }

        case rr.type
        when :A, :AAAA, :CNAME, :TXT
          set_record(rr)
        when :SRV, :PTR
          add_record(rr)
        else
          raise InvalidRequest,
            "Don't know how to publish a #{rr.type} record"
        end
      end
    rescue InvalidRequest
      raise
    rescue StandardError => ex
      #:nocov:
      @logger.error(progname) do
        (["Error while publishing record #{rr.inspect}: #{ex.message} (#{ex.class})"] + ex.backtrace).join("\n  ")
      end
      #:nocov:
    end

    def suppress_record(rr)
      @request_stats.measure(op: "suppress", rrtype: rr.type.to_s) do
        @logger.debug(progname) { "Suppressing record #{rr.name} #{rr.ttl} #{rr.type} #{rr.value}" }

        case rr.type
        when :A
          if rr.name =~ /\A(\d+-\d+-\d+-\d+\.)?[^.]+\z/
            # This record represents an IPv4 address that is (or could be) shared
            # amongst many machines; that means we can't remove it now, in case
            # it's used elsewhere.  We'll defer this for another time
            @logger.debug(progname) { "Detected #{rr.name} as a shared record" }
            @shared_records[rr] = true
          else
            remove_record(rr)
          end
        when :AAAA, :CNAME
          remove_record(rr)
        when :SRV
          remove_srv_record(rr)
        when :TXT, :PTR
          raise InvalidRequest,
            "Cannot unconditionally suppress a #{rr.type} record"
        else
          raise InvalidRequest,
            "Don't know how to suppress a #{rr.type} record"
        end
      end
    rescue InvalidRequest
      raise
    rescue StandardError => ex
      #:nocov:
      @logger.error(progname) do
        (["Error while suppressing record #{rr.inspect}: #{ex.message} (#{ex.class})"] + ex.backtrace).join("\n  ")
      end
      #:nocov:
    end

    def suppress_shared_records
      @shared_records.keys.each { |rr| remove_record(rr) }
      if @config.host_dns_record
        suppress_record(@config.host_dns_record)
      end
    end

    def rest
      # Called when it's likely that nothing is going to happen for a while
    end

    private

    def progname
      self.class.to_s
    end

    def backend_config
      @config.backend_configs[name]
    end

    def base_domain
      # an absolute Name
      Resolv::DNS::Name.create((backend_config["BASE_DOMAIN"] || @config.base_domain) + '.')
    end
  end
end

# frozen_string_literal: true
require 'logger'
require 'ipaddr'
require 'prometheus/client'

require 'ddnssd/docker_watcher'

module DDNSSD
  class Config
    # Raised if any problems were found with the config
    class InvalidEnvironmentError < StandardError; end

    attr_reader :hostname,
                :base_domain,
                :ipv6_only,
                :enable_metrics,
                :record_ttl,
                :host_ip_address,
                :docker_host,
                :validate_ports,
                :logger,
                :backend_classes,
                :backend_configs

    attr_reader :metrics_registry

    # Create a new DDNS-SD system config based on environment variables.
    #
    # Examines the environment passed in, and then creates a new system
    # object if all is well.
    #
    # @param env [Hash] the set of environment variables to use.
    #
    # @param logger [Logger] the logger to which all diagnostic and error
    #   data will be sent.
    #
    # @return [DDNSSD::Config]
    #
    # @raise [InvalidEnvironmentError] if any problems are detected with the
    #   environment variables found.
    #
    def initialize(env, logger:)
      @logger = logger

      parse_env(env)
    end

    def host_dns_record
      @host_dns_record ||= begin
        if @host_ip_address
          DDNSSD::DNSRecord.new(@hostname, @record_ttl, @ipv6_only ? :AAAA : :A, @host_ip_address)
        else
          nil
        end
      end
    end

    private

    def parse_env(env)
      @hostname        = pluck_hostname(env, "DDNSSD_HOSTNAME")
      @base_domain     = pluck_fqdn(env, "DDNSSD_BASE_DOMAIN")
      @ipv6_only       = pluck_boolean(env, "DDNSSD_IPV6_ONLY", default: false)
      @enable_metrics  = pluck_boolean(env, "DDNSSD_ENABLE_METRICS", default: false)
      @record_ttl      = pluck_integer(env, "DDNSSD_RECORD_TTL", valid_range: 0..(2**31 - 1), default: 60)
      @host_ip_address = @ipv6_only ?
        pluck_ipv6_address(env, "DDNSSD_HOST_IP_ADDRESS", default: nil)
        : pluck_ipv4_address(env, "DDNSSD_HOST_IP_ADDRESS", default: nil)
      @docker_host     = pluck_string(env, "DOCKER_HOST", default: "unix:///var/run/docker.sock")
      @validate_ports  = pluck_boolean(env, "DDNSSD_VALIDATE_PORTS", default: true)
      @backend_classes = find_backend_classes(env)
      @backend_configs = pluck_backend_configs(env)

      # Even if we're not actually *running* a metrics server, we still need
      # the registry in place, because conditionalising every metrics-related
      # operation on whether metrics are enabled is just... madness.
      @metrics_registry = Prometheus::Client::Registry.new
    end

    def pluck_hostname(env, key)
      if env[key].nil? || env[key].empty?
        raise InvalidEnvironmentError,
              "Required environment variable #{key} not specified"
      end

      unless env[key] =~ /\A(?!-)[a-zA-Z0-9-]{1,63}(?<!-)\z/
        raise InvalidEnvironmentError,
          "Value for #{key} (#{env[key].inspect}) is not a valid hostname"
      end

      env[key]
    end

    def pluck_fqdn(env, key)
      if env[key].nil? || env[key].empty?
        raise InvalidEnvironmentError,
              "Required environment variable #{key} not specified"
      end

      unless env[key] =~ /(?=\A.{4,253}$)(^((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,63}\z)/
        raise InvalidEnvironmentError,
          "Value for #{key} (#{env[key].inspect}) is not a valid FQDN"
      end

      env[key]
    end

    def pluck_boolean(env, key, default: nil)
      if env[key].nil? || env[key].empty?
        return default
      end

      case env[key]
      when /\A(no|off|0|false)\z/
        false
      when /\A(yes|on|1|true)\z/
        true
      else
        raise InvalidEnvironmentError,
          "Value for #{key} (#{env[key].inspect}) is not a valid boolean value"
      end
    end

    def pluck_integer(env, key, valid_range: nil, default: nil)
      if env[key].nil? || env[key].empty?
        return default
      end

      if env[key] !~ /\A\d+\z/
        raise InvalidEnvironmentError,
          "Value for #{key} (#{env[key].inspect}) is not an integer"
      end

      v = env[key].to_i
      unless valid_range.nil?
        unless valid_range.include?(v)
          raise InvalidEnvironmentError,
            "Value for #{key} (#{env[key]}) out of range (must be between #{valid_range.first} and #{valid_range.last} inclusive)"
        end
      end

      v
    end

    def pluck_string(env, key, default: nil)
      if env[key].nil? || env[key].empty?
        return default
      end

      env[key]
    end

    def pluck_ipv4_address(env, key, default: nil)
      if env[key].nil? || env[key].empty?
        return default
      end

      begin
        addr = IPAddr.new(env[key])
      rescue ArgumentError
        raise InvalidEnvironmentError,
          "Value for #{key} (#{env[key].inspect}) is not an IP address"
      end

      unless addr.ipv4?
        raise InvalidEnvironmentError,
          "Value for #{key} (#{env[key].inspect}) is not an IPv4 address"
      end

      addr.to_s
    end

    def pluck_ipv6_address(env, key, default: nil)
      if env[key].nil? || env[key].empty?
        return default
      end

      begin
        addr = IPAddr.new(env[key])
      rescue ArgumentError
        raise InvalidEnvironmentError,
          "Value for #{key} (#{env[key].inspect}) is not an IP address"
      end

      unless addr.ipv6?
        raise InvalidEnvironmentError,
          "Value for #{key} (#{env[key].inspect}) is not an IPv6 address"
      end

      addr.to_s
    end

    def find_backend_classes(env)
      backend_list = env["DDNSSD_BACKEND"]
      if backend_list.nil? || backend_list.empty?
        raise InvalidEnvironmentError, "Required environment variable DDNSSD_BACKEND not specified."
      end

      backend_list.split(/\s*,\s*/).map do |name|
        resolve_backend_name(name)
      end
    end

    def resolve_backend_name(name)
      begin
        require "ddnssd/backend/#{name}"
      rescue LoadError => ex
        raise InvalidEnvironmentError, "Unknown backend #{name.inspect}"
      end

      ObjectSpace.each_object(Class) do |klass|
        if klass.respond_to?(:backend_name) && klass.backend_name == name
          # We got a live one here!
          return klass
        end
      end

      #:nocov:
      raise InvalidEnvironmentError,
        "Backend #{name.inspect} does not exist"
      #:nocov:
    end

    def pluck_backend_configs(env)
      {}.tap do |backend_configs|
        find_backend_classes(env).map(&:backend_name).each do |backend_name|
          prefix = "DDNSSD_#{backend_name.upcase}_"

          backend_configs[backend_name] = Hash[env.select { |k, v| k.start_with? prefix }.map { |k, v| [k.sub(/\A#{prefix}/, ''), v] }]
        end
      end
    end
  end
end

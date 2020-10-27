# frozen_string_literal: true

require 'shellwords'

require 'ddnssd/backend'
require 'ddnssd/config'
require 'ddnssd/dns_record'
require 'ddnssd/error'
require 'ddnssd/power_dns/resource_record_store'

require 'pg'
require 'mini_sql'
require 'dns-sd'

class DDNSSD::Backend::PowerDNS < DDNSSD::Backend

  class PGServerNotFound < DDNSSD::Error; end

  def initialize(config)
    super

    %w(PG_DBNAME PG_USER PG_PASSWORD).each do |env_var|
      if (backend_config[env_var] || '').empty?
        raise DDNSSD::Config::InvalidEnvironmentError,
          "DDNSSD_POWER_DNS_#{env_var} cannot be empty or missing"
      end
    end

    if (backend_config['PG_DNSNAME'] || '').empty? &&
      (backend_config['PG_HOST'] || '').empty?
      raise DDNSSD::Config::InvalidEnvironmentError,
        "Either DDNSSD_POWER_DNS_PG_DNSNAME or DDNSSD_POWER_DNS_PG_HOST must be given"
    end

    if backend_config['PG_DNSNAME']
      @pg_instance, service, @pg_domain = parse_dnsname(backend_config['PG_DNSNAME'])
      if service != '_postgresql._tcp'
        raise DDNSSD::Config::InvalidEnvironmentError,
          "DDNSSD_POWER_DNS_PG_DNSNAME must be for a postgresql tcp service"
      end
      @pg_dnssd = DNSSD.new(@pg_domain)
    end

    @pg_dbname = backend_config['PG_DBNAME']
    @pg_user = backend_config['PG_USER']
    @pg_password = backend_config['PG_PASSWORD']

    @stats = Frankenstein::Request.new(
      :ddnssd_power_dns,
      description: "power_dns",
      registry: @config.metrics_registry
    )
  end

  def db
    @conn ||= begin
      pg_targets = if backend_config['PG_HOST']
        [DNSSD::Target.new(backend_config['PG_HOST'], backend_config['PG_PORT']&.to_i || 5432)]
      else
        @pg_dnssd.service_instance(@pg_instance, 'postgresql', :TCP).targets
      end

      @pg_conn = nil

      pg_targets.each do |target|
        begin
          @pg_conn = PG.connect(
            host: target.hostname,
            port: target.port,
            dbname: @pg_dbname,
            user: @pg_user,
            password: @pg_password,
            sslmode: 'prefer'
          )
          @logger.debug(progname) { "Successfully connected to PostgreSQL at #{target.hostname}:#{target.port}" }
          break
        rescue
        end
      end

      if @pg_conn
        MiniSql::Connection.get(@pg_conn)
      else
        raise PGServerNotFound
      end
    end
  end

  def rest
    if @pg_conn
      begin
        @pg_conn.close
        @logger.debug(progname) { "Closed connection to postgresql." }
      rescue
        nil
      end
    end
    @conn = nil
  end

  def dns_records
    all_records = @stats.measure(op: "list") do
      retryable { resource_record_store.all }
    end

    all_records.map do |rr|
      rrdata = if rr.type == 'TXT'
        Shellwords.shellwords(rr.content)
      else
        rr.content.split(/\s+/).map { |v| v =~ /\A\d+\z/ ? v.to_i : v }
      end

      dns_record = DDNSSD::DNSRecord.new("#{rr.name}.", rr.ttl, rr.type.to_sym, *rrdata)

      if DDNSSD::Backend::PUBLISHABLE_TYPES.include?(dns_record.type)
        if dns_record.subdomain_of?(base_domain)
          dns_record.to_relative(base_domain)
        else
          @logger.warn(progname) { "Found a record with a value that isn't a subdomain of #{base_domain}. Ignoring it. #{dns_record.inspect}" }
          nil
        end
      else
        # import SOA and others as is
        dns_record
      end
    end.compact
  end

  def set_record(rr)
    @logger.debug(progname) { "-> set_record(#{rr.short_inspect} #{rr.inspect})" }
    @stats.measure(op: "set") do
      retryable { resource_record_store.upsert(rr.to_absolute(base_domain)) }
    end
    @logger.debug(progname) { "<- set_record(#{rr.short_inspect} #{rr.inspect})" }
  end

  def add_record(rr)
    @logger.debug(progname) { "-> add_record(#{rr.short_inspect} #{rr.inspect})" }
    @stats.measure(op: "add") do
      retryable { resource_record_store.add(rr.to_absolute(base_domain)) }
    end
    @logger.debug(progname) { "<- add_record(#{rr.short_inspect} #{rr.inspect})" }
  end

  def remove_record(rr)
    @logger.debug(progname) { "-> remove_record(#{rr.short_inspect} #{rr.inspect})" }
    @stats.measure(op: "remove") do
      retryable { resource_record_store.remove(rr.to_absolute(base_domain)) }
    end
    @logger.debug(progname) { "<- remove_record(#{rr.short_inspect} #{rr.inspect})" }
  end

  def remove_srv_record(rel_srv_record)
    @logger.debug(progname) { "-> remove_srv_record(#{rel_srv_record.short_inspect} #{rel_srv_record.inspect})" }

    srv_record = rel_srv_record.to_absolute(base_domain)

    @stats.measure(op: "remove_srv") do
      retryable do
        begin
          db.exec('BEGIN')

          count = resource_record_store.remove(srv_record)

          if count > 0
            other_srv_records = resource_record_store.lookup(type: :SRV, name: srv_record.name)

            if other_srv_records.size == 0
              txt_count = resource_record_store.remove_with(type: :TXT, name: srv_record.name)

              if txt_count == 0
                #:nocov:
                @logger.warn(progname) { "TXT record for SRV #{srv_record.name} is missing?!?" }
                #:nocov:
              elsif txt_count > 1
                # :nocov:
                @logger.warn(progname) { "Found #{txt_count} TXT records for #{srv_record.name}! Removed all of them." }
                # :nocov:
              end

              resource_record_store.remove_with(
                type: :PTR,
                name: srv_record.parent_name,
                content: srv_record.name
              )
            end
          else
            #:nocov:
            @logger.warn(progname) { "no existing record to remove for #{srv_record.inspect}" }
            #:nocov:
          end

          db.exec('COMMIT')
        rescue => ex
          db.exec('ROLLBACK')
          raise ex
        end # transaction
      end # retryable
    end

    @logger.debug(progname) { "<- remove_srv_record(#{rel_srv_record.short_inspect} #{rel_srv_record.inspect})" }
  end

  private

  def progname
    @logger_progname ||= "#{self.class.name}(#{base_domain})"
  end

  def resource_record_store
    @resource_record_store ||=
      DDNSSD::PowerDNS::ResourceRecordStore.new(self, base_domain.to_s, @logger)
  end

  def next_timeout(prev_timeout = nil)
    if prev_timeout.nil?
      0.5 + rand / 2
    else
      prev_timeout * 1.1 + rand
    end
  end

  def retryable
    retry_count = 0
    timeout = next_timeout

    begin
      yield
    rescue PG::Error, PGServerNotFound => ex
      if @pg_conn
        @pg_conn.close rescue nil
      end
      @conn = nil # reconnect on next attempt
      retry_count += 1
      timeout = next_timeout(timeout)
      @logger.info(progname) { "Received #{ex.class} on attempt #{retry_count}; waiting for #{timeout}s and retrying" }
      Kernel.sleep timeout
      retry
    end
  end

  def parse_dnsname(str)
    parts = str.split('.')
    l = parts.index { |v| v.start_with?('_') }
    r = parts.rindex { |v| v.start_with?('_') }
    [parts[0...l].join('.'), parts[l..r].join('.'), parts[(r + 1)..-1].join('.')]
  end
end

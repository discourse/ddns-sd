# frozen_string_literal: true
require 'azure_mgmt_dns'
require 'shellwords'

require 'ddnssd/backend'
require 'ddnssd/config'
require 'ddnssd/dns_record'
require 'ddnssd/error'

include Azure::Dns::Mgmt::V2018_03_01_preview
include Azure::Dns::Mgmt::V2018_03_01_preview::Models

class DDNSSD::Backend::Azure < DDNSSD::Backend
  class RetryError < DDNSSD::Error; end
  class InvalidChangeRequest < DDNSSD::Error; end

  module Retryable
    def retryable
      next_timeout = 0.1
      tries_left = 10

      begin
        tries_left -= 1
        yield
      rescue StandardError => ex
        if tries_left > 0
          @logger.info(progname) { "Received #{ex.class}; waiting for #{next_timeout}s and retrying" }
          Kernel.sleep next_timeout
          next_timeout *= 2
          retry
        else
          @logger.info(progname) { "Received #{ex.class} - #{ex.message}.\n #{ex.backtrace.join("\n")}" }
          raise RetryError, "Attempted request 10 times, got a retryable error every time. This is not normal. Giving up."
        end
      end
    end
  end

  module RecordSetHelper
    def az_to_dnssd_rset_type(rrset)
      rrset.type.split("/").last.to_sym
    end

    def az_to_dnssd_rset_name(rrset)
      rrset.name&.chomp('.') || ''
    end

    def az_to_dnssd_records(rrset)
      record_type = az_to_dnssd_rset_type(rrset)
      full_name = az_to_dnssd_rset_name(rrset)
      zone_str = ".#{@zone_name}"

      records_raw =
        case record_type
        when :A then rrset.arecords.map { |r| { type: "A", value: r.ipv4address } }
        when :AAAA then rrset.aaaa_records.map { |r| { type: "AAAA", value: r.ipv6address } }
        when :NS then rrset.ns_records.map { |r| { type: "NS", value: r.nsdname } }
        when :PTR then rrset.ptr_records.map { |r| { type: "PTR", value: r.ptrdname } }
        when :SRV then rrset.srv_records.map { |r| { type: "SRV", value: "#{ r.priority } #{ r.weight } #{ r.port } #{ r.target.chomp(zone_str) }" } }
        when :TXT then rrset.txt_records.map { |r| { type: "TXT", value: r.value } }
        when :CNAME then [{ type: "CNAME", value: rrset.cname_record.cname.chomp(zone_str) }]
        when :SOA then [{ type: "SOA", value: "#{ rrset.soa_record.host } #{ rrset.soa_record.email } #{ rrset.soa_record.serial_number } #{ rrset.soa_record.refresh_time } #{ rrset.soa_record.retry_time } #{ rrset.soa_record.expire_time } #{ rrset.soa_record.minimum_ttl }" }]
        else []
        end

      records_raw.map do |rr|
        rrdata = if record_type == :TXT
          rr[:value]
        else
          rr[:value].split(/\s+/).map { |v| v =~ /\A\d+\z/ ? v.to_i : v }
        end

        DDNSSD::DNSRecord.new(full_name, rrset.ttl, record_type, *rrdata)
      end
    end

    def dnssd_to_az_name(name)
      # we use relative names, they use relative names, hurray!
      name.to_s
    end

    def dnssd_to_az_records(records)
      r = records.first
      rrset = RecordSet.new
      rrset.ttl = r.ttl
      rrset.name = dnssd_to_az_name r.name
      rrset.type = r.type.to_s
      case r.type
      when :A then rrset.arecords = records.map { |r|
                      ar = ARecord.new
                      ar.ipv4address = r.value
                      ar }
      when :AAAA then rrset.aaaa_records = records.map { |r|
                         ar = AaaaRecord.new
                         ar.ipv6address = r.value
                         ar  }
      when :PTR then rrset.ptr_records = records.map { |r|
                        ar = PtrRecord.new
                        ar.ptrdname = r.value
                        ar }
      when :SRV then rrset.srv_records = records.map { |r|
                        v = r.value.split(" ")
                        ar = SrvRecord.new
                        ar.priority = v[0]
                        ar.weight = v[1]
                        ar.port = v[2]
                        ar.target = "#{v[3]}.#{@zone_name}"
                        ar }
      when :TXT then rrset.txt_records = records.map { |r|
                        # Hack to get azure to update with blank txt records
                        ar = TxtRecord.new
                        ar.value =
                          if r.data.strings.reject { |er| er.empty? }.empty?
                            [" "]
                          else
                            r.data.strings
                          end
                        ar }
      when :CNAME then rrset.cname_record = records.map { |r|
                          ar = CnameRecord.new
                          ar.cname = "#{r.value}.#{@zone_name}"
                          ar }.first
      end
      @logger.debug(progname) { "-> dnssd_to_az_records(#{rrset.inspect})" }
      rrset
    end
  end

  include Retryable
  include RecordSetHelper

  class RecordCache
    include Retryable
    include RecordSetHelper

    def initialize(client, resource_group_name, zone_name, logger)
      @client, @resource_group_name, @zone_name, @logger = client, resource_group_name, zone_name, logger

      blank_cache
    end

    def get(name, type)
      @cache[name][type]
    end

    def get_etag(name, type)
      @etag_cache[name][type]
    end

    def all_of_type(type)
      @cache.values.map { |v| v[type] }.flatten.compact
    end

    def add(etag, rr)
      @cache[rr.name][rr.type] << rr unless @cache[rr.name][rr.type].include?(rr)
      @etag_cache[rr.name][rr.type] = etag
    end

    def remove(rr)
      @cache[rr.name][rr.type].delete(rr)
      @etag_cache[rr.name][rr.type] = nil
    end

    def set(etag, *rr)
      @cache[rr.first.name][rr.first.type] = rr
      @etag_cache[rr.first.name][rr.first.type] = etag
    end

    def refresh_all
      blank_cache

      all_resource_record_sets do |rrset|
        import_rrset(rrset)
      end
    end

    def refresh(name, type)
      rrset = retryable do
        begin
          @client.record_sets.get(@resource_group_name, @zone_name, dnssd_to_az_name(name), type.to_s)
        rescue MsRestAzure::AzureOperationError
          nil
        end
      end

      if rrset
        import_rrset(rrset)
      else
        @cache[name][type] = []
        @etag_cache[name][type] = nil
      end
    end

    def blank_cache
      @cache = Hash.new do |oh, ok|
        oh[ok] = Hash.new { |ih, ik| ih[ik] = [] }
      end
      @etag_cache = Hash.new do |oh, ok|
        oh[ok] = Hash.new { |ih, ik| ih[ik] = nil }
      end
    end

    private

    def progname
      @logger_progname ||= "DDNSSD::Backend::Azure(#{@zone_name})"
    end

    def all_resource_record_sets
      res = @client.record_sets.list_by_dns_zone(@resource_group_name, @zone_name)
      @logger.debug(progname) { "all_resource_record_sets #{res.inspect}" }

      res.each { |rrset| yield rrset }

    rescue StandardError => ex
      @logger.error(progname) { (["Error while enumerating all_resource_record_sets: #{ex.message} (#{ex.class})"] + ex.backtrace).join("  \n") }
    end

    def import_rrset(rrset)
      record_type = az_to_dnssd_rset_type rrset
      name = az_to_dnssd_rset_name rrset
      records = az_to_dnssd_records(rrset)
      @cache[name][record_type] = records
      @etag_cache[name][record_type] = rrset.etag
    end
  end

  def initialize(config)
    super

    @zone_name = base_domain.to_s
    @resource_group_name = backend_config["RESOURCE_GROUP_NAME"]
    @access_token = backend_config["ACCESS_TOKEN"]

    if @resource_group_name.nil? || @resource_group_name.empty?
      raise DDNSSD::Config::InvalidEnvironmentError,
            "DDNSSD_AZURE_RESOURCE_GROUP_NAME cannot be empty or missing"
    end
    if @access_token.nil? || @access_token.empty?
      raise DDNSSD::Config::InvalidEnvironmentError,
            "DDNSSD_AZURE_ACCESS_TOKEN cannot be empty or missing"
    end
    @access_token = @access_token.gsub(/\A"|"\Z/, '')

    account = JSON.parse(@access_token)
    credentials = MsRest::TokenCredentials.new(account["accessToken"])

    @client = DnsManagementClient.new(credentials)
    @client.subscription_id = account["subscription"]

    @record_cache = RecordCache.new(@client, @resource_group_name, @zone_name, @logger)
  end

  def dns_records
    @record_cache.refresh_all

    %i{A AAAA SRV PTR TXT CNAME}.map do |type|
      @record_cache.all_of_type(type)
    end.flatten
  end

  private

  def progname
    @logger_progname ||= "DDNSSD::Backend::Azure(#{@zone_name})"
  end

  def set_record(rr)
    @logger.debug(progname) { "-> set_record(#{rr.inspect})" }
    az_records = create_or_update [rr]
    @record_cache.set(az_records.etag, rr)
    @logger.debug(progname) { "<- set_record(#{rr.inspect})" }
  end

  def add_record(rr)
    @logger.debug(progname) { "-> add_record(#{rr.inspect})" }

    tries_left = 10

    begin
      tries_left -= 1

      existing_records = @record_cache.get(rr.name, rr.type)

      if existing_records.empty?
        az_records = create [rr]
      else
        az_records = update (existing_records + [rr]).uniq
      end

      @record_cache.add(az_records.etag, rr)
      @logger.debug(progname) { "<- add_record(#{rr.inspect})" }
    rescue MsRestAzure::AzureOperationError => ex
      if tries_left > 0
        @logger.debug(progname) { "Received InvalidChangeBatch; refreshing record set for #{rr.name} #{rr.type}" }

        @record_cache.refresh(rr.name, rr.type)

        @logger.debug(progname) { "record set for #{rr.name} #{rr.type} is now #{@record_cache.get(rr.name, rr.type).inspect}" }
        @logger.debug(progname) { "record set etag for #{rr.name} #{rr.type} is now #{@record_cache.get_etag(rr.name, rr.type).inspect}" }
        retry
      else
        @logger.error(progname) { "Cannot get this add_record change to apply, because #{ex.message}. Giving up." }
      end
    end
  end

  def remove_record(rr)
    @logger.debug(progname) { "-> remove_record(#{rr.inspect})" }

    tries_left = 10

    begin
      tries_left -= 1
      change_to_remove_record_from_set(@record_cache.get(rr.name, rr.type), rr)
      @record_cache.remove(rr)
      @logger.debug(progname) { "<- remove_record(#{rr.inspect})" }
    rescue MsRestAzure::AzureOperationError => ex
      if tries_left > 0
        @logger.debug(progname) { "Received InvalidChangeBatch; refreshing record set for #{rr.name} #{rr.type}" }

        @record_cache.refresh(rr.name, rr.type)
        retry
      else
        @logger.error(progname) { "Cannot get this remove_record change to apply, because #{ex.message}. Giving up." }
      end
    end
  end

  def remove_srv_record(srv_rr)
    @logger.debug(progname) { "-> remove_srv_record(#{srv_rr.inspect})" }

    tries_left = 10

    begin
      tries_left -= 1

      existing_records = @record_cache.get(srv_rr.name, srv_rr.type).dup

      if existing_records.empty?
        # Shouldn't happen!
        #:nocov:
        @logger.warn(progname) { "no existing record to remove for #{srv_rr.inspect}" }
        #:nocov:
      elsif existing_records == [srv_rr]
        delete existing_records

        txt = @record_cache.get(srv_rr.name, :TXT)
        unless txt.empty?
          @logger.debug(progname) { "Removing associated TXT record" }
          delete txt
        else
          # Shouldn't happen...
          #:nocov:
          @logger.warn(progname) { "TXT record for #{srv_rr.name} is missing?!?" }
          #:nocov:
        end

        ptrs = @record_cache.get(srv_rr.parent_name, :PTR)
        ptr = ptrs.find { |ptr| ptr.value == srv_rr.name }

        if ptr
          @logger.debug(progname) { "Removing associated PTR record #{ptr.inspect}" }
          change_to_remove_record_from_set(ptrs, ptr)
        end
      else
        change_to_remove_record_from_set(existing_records, srv_rr)
      end

      unless existing_records.empty?
        @record_cache.remove(srv_rr)

        if existing_records == [srv_rr]
          # We nuked these
          @record_cache.get(srv_rr.name, :TXT).each { |txt| @record_cache.remove(txt) }
          @record_cache.remove(ptr) if ptr
        end
      end

      @logger.debug(progname) { "<- remove_srv_record(#{srv_rr.inspect})" }
    rescue StandardError => ex

      if tries_left > 0
        @logger.debug(progname) { "Received InvalidChangeBatch; refreshing record set for #{srv_rr.name} #{srv_rr.type}/TXT" }

        @record_cache.refresh(srv_rr.name, srv_rr.type)
        @record_cache.refresh(srv_rr.name, :TXT)
        @record_cache.refresh(srv_rr.parent_name, :PTR)

        retry
      else
        @logger.error(progname) { "Cannot get this remove_srv_record change to apply, because #{ex.message}. Giving up." }
      end
    end
  end

  def change_to_remove_record_from_set(rrset, rr)
    @logger.debug(progname) { "change_to_remove_record_from_set(#{rrset.inspect}, #{rr.inspect})" }

    if rrset.any? { |s| s.name != rr.name }
      # Purely an (in)sanity check
      #:nocov:
      raise InvalidChangeRequest,
        "One or more entries in rrset #{rrset.inspect} have a different name to #{rr}."
      #:nocov:
    end

    if rrset.nil?
      # *Really* shouldn't happen...
      #:nocov:
      raise InvalidChangeRequest,
        "rrset passed was nil!"
      #:nocov:
    elsif rrset.empty?
      # *Shouldn't* happen...
      #:nocov:
      @logger.warn(progname) { "Attempted to delete #{rr.inspect} from empty rrset." }
      []
      #:nocov:
    elsif rrset.reject { |er| er.value == rr.value }.empty?
      delete rrset
    else
      update rrset.reject { |er| er.value == rr.value }
    end
  end

  def update(records)
    r = records.first
    records = dnssd_to_az_records(records)
    etag = @record_cache.get_etag(r.name, r.type)
    @client.record_sets.update(@resource_group_name, @zone_name, dnssd_to_az_name(r.name), r.type.to_s, records, if_match: etag)
  end

  def create_or_update(records)
    r = records.first
    records = dnssd_to_az_records(records)
    @client.record_sets.create_or_update(@resource_group_name, @zone_name, dnssd_to_az_name(r.name), r.type.to_s, records)
  end

  def create(records)
    r = records.first
    records = dnssd_to_az_records(records)
    # create_or_update with if none match to prevent updating an existing record set.
    # https://github.com/Azure/azure-sdk-for-ruby/blob/master/management/azure_mgmt_dns/lib/2018-03-01-preview/generated/azure_mgmt_dns/record_sets.rb#L182
    @client.record_sets.create_or_update(@resource_group_name, @zone_name, dnssd_to_az_name(r.name), r.type.to_s, records, if_none_match: "*")
  end

  def delete(records)
    r = records.first
    etag = @record_cache.get_etag(r.name, r.type)
    @client.record_sets.delete(@resource_group_name, @zone_name, dnssd_to_az_name(r.name), r.type.to_s, if_match: etag)
  end
end

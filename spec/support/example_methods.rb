# frozen_string_literal: true
require 'docker-api'
require 'resolv'
require 'yaml'

module ExampleMethods
  def container_fixture(name)
    data = YAML.load_file(File.expand_path("../../fixtures/container_data/#{name}.yml", __FILE__))
    Docker::Container.send(:new, Docker::Connection.new("unix:///", {}), data)
  end

  def container_fixtures(*names)
    names.map { |n| container_fixture(n) }
  end

  def dns_record_fixture(name)
    data = YAML.load_file(File.expand_path("../../fixtures/dns_records/#{name}.yml", __FILE__))
    data.map { |d| DDNSSD::DNSRecord.new(d["name"], d["ttl"], d["type"], *d["data"]) }
  end

  def dns_record_fixtures(*names)
    names.map { |n| dns_record_fixture(n) }.flatten(1)
  end

  def with_overridden_constant(mod, const, value)
    exists, original_value = if mod.const_defined?(const)
      [true, mod.const_get(const)]
    else
      [false, nil]
    end

    mod.__send__ :remove_const, const
    mod.const_set(const, value)

    yield

    mod.__send__ :remove_const, const

    if exists
      mod.const_set(const, original_value)
    end
  end

  def route53_response_fixture(name)
    YAML.load_file(File.expand_path("../../fixtures/route53_responses/#{name}.yml", __FILE__))
  end

  def azure_response_fixture(name)
    client = Azure::Dns::Mgmt::V2018_03_01_preview::DnsManagementClient.new
    json = File.read(File.expand_path("../../fixtures/azure_responses/#{name}.json", __FILE__))
    request_mapper = Azure::Dns::Mgmt::V2018_03_01_preview::Models::RecordSet.mapper
    records = JSON.parse(json).map { |v| client.deserialize(request_mapper, v) }
    records.map { |rs|
      rs.type =
        case
        when !rs.arecords.nil? then "Microsoft.Network/dnszones/A"
        when !rs.aaaa_records.nil? then "Microsoft.Network/dnszones/AAAA"
        when !rs.mx_records.nil? then "Microsoft.Network/dnszones/MX"
        when !rs.ns_records.nil? then "Microsoft.Network/dnszones/NS"
        when !rs.ptr_records.nil? then "Microsoft.Network/dnszones/PTR"
        when !rs.srv_records.nil? then "Microsoft.Network/dnszones/SRV"
        when !rs.txt_records.nil? then "Microsoft.Network/dnszones/TXT"
        when !rs.cname_record.nil? then "Microsoft.Network/dnszones/CNAME"
        when !rs.soa_record.nil? then "Microsoft.Network/dnszones/SOA"
        when !rs.caa_records.nil? then "Microsoft.Network/dnszones/CAA"
        else "no value...?"
        end
      rs }
  end
end

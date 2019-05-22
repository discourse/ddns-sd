# frozen_string_literal: true
require_relative './spec_helper'

require 'ddnssd/backend/azure'

include Azure::Dns::Mgmt::V2018_03_01_preview
include Azure::Dns::Mgmt::V2018_03_01_preview::Models

describe DDNSSD::Backend::Azure do
  uses_logger

  RSpec::Matchers.define :match_azure_record do |x|
    match do |actual|
      client = DnsManagementClient.new
      request_mapper = Azure::Dns::Mgmt::V2018_03_01_preview::Models::RecordSet.mapper
      @actual = client.serialize(request_mapper, actual)
      if @actual != x
        #puts "expected #{ x.inspect} but got #{ @actual.inspect }"
      end
      @actual == x
    end
  end

  let(:rg) { "ddns-test" }
  let(:zone) { "example.com" }
  let(:base_env) do
    {
      "DDNSSD_HOSTNAME"        => "speccy",
      "DDNSSD_BACKEND"         => "azure",
      "DDNSSD_BASE_DOMAIN"     => zone,
      "DDNSSD_AZURE_RESOURCE_GROUP_NAME" => rg,
      "DDNSSD_AZURE_ACCESS_TOKEN" => { accessToken: "flibber",
                                       expiresOn: "2018-08-02 11:29:51.706962",
                                       subscription: "123123123-1234-1234-1234-1234123123123",
                                       tenant: "123123123-1234-1234-1234-1234123123123",
                                       tokenType: "Bearer"
                                     }.to_json,
    }
  end
  let(:env) { base_env }
  let(:config) { DDNSSD::Config.new(env, logger: logger) }

  let(:backend) { DDNSSD::Backend::Azure.new(config) }

  let(:az_client) { DnsManagementClient.new }

  before(:each) do
    allow(Azure::Dns::Mgmt::V2018_03_01_preview::DnsManagementClient).to receive(:new).and_return(az_client)
    allow(MsRest::TokenCredentials).to receive(:new).and_return(nil)
  end

  describe ".new" do
    context "without a RESOURCE_GROUP specified" do
      let(:env) { base_env.reject { |k, v| k == "DDNSSD_AZURE_RESOURCE_GROUP_NAME" } }

      it "raises an exception" do
        expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end
    end

    context "without an ACCESS_TOKEN specified" do
      let(:env) { base_env.reject { |k, v| k == "DDNSSD_AZURE_ACCESS_TOKEN" } }

      it "raises an exception" do
        expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end
    end
  end

  describe "#dns_records" do
    context "one page of records" do
      before(:each) do
        allow(az_client.record_sets).to receive(:list_by_dns_zone).and_return(azure_response_fixture("basic_response"))
      end

      it "asks for the records of the correct resource group and base domain" do
        expect(az_client.record_sets).to receive(:list_by_dns_zone).with(rg, zone).and_return(azure_response_fixture("basic_response"))

        backend.dns_records
      end

      it "returns a list of DDNSSD::DNSRecord objects" do
        expect(backend.dns_records).to be_an(Array)
        expect(backend.dns_records.reject { |rr| DDNSSD::DNSRecord === rr }).to be_empty
        expect(backend.dns_records.all? { |rr| DDNSSD::DNSRecord === rr }).to be(true)
      end

      it "returns A records" do
        expect(backend.dns_records.any? { |rr| rr.type == :A }).to be(true)
      end

      it "returns AAAA records" do
        expect(backend.dns_records.any? { |rr| rr.type == :AAAA }).to be(true)
      end

      it "returns CNAME records" do
        expect(backend.dns_records.any? { |rr| rr.type == :CNAME }).to be(true)
      end

      it "returns SRV records" do
        expect(backend.dns_records.any? { |rr| rr.type == :SRV }).to be(true)
      end

      it "returns TXT records" do
        expect(backend.dns_records.any? { |rr| rr.type == :TXT }).to be(true)
      end

      it "returns PTR records" do
        expect(backend.dns_records.any? { |rr| rr.type == :PTR }).to be(true)
      end

      it "does not return SOA records" do
        expect(backend.dns_records.any? { |rr| rr.type == :SOA }).to be(false)
      end

      it "does not return NS records" do
        expect(backend.dns_records.any? { |rr| rr.type == :NS }).to be(false)
      end

      it "converts unsupported record types to an empty record set" do
        rrset = Azure::Dns::Mgmt::V2018_03_01_preview::Models::RecordSet.new
        rrset.type = "test/other"
        rrset.name = "test"
        expect(backend.az_to_dnssd_records(rrset)).to eq([])

      end
    end

    context "on other errors" do
      before(:each) do
        allow(az_client.record_sets).to receive(:list_by_dns_zone).and_return("oogabooga")
        allow(logger).to receive(:error)
      end

      it "logs the error" do
        expect(logger).to receive(:error)

        backend.dns_records
      end

      it "returns an empty list" do
        expect(backend.dns_records).to be_empty
      end
    end
  end

  describe "#publish_record" do

    before(:each) do
      allow(az_client.record_sets).to receive(:create_or_update).and_return(OpenStruct.new(etag: "1"))
      allow(az_client.record_sets).to receive(:update).and_return(OpenStruct.new(etag: "1"))
      allow(az_client.record_sets).to receive(:create).and_return(OpenStruct.new(etag: "1"))
    end

    context "with an NS record" do
      it "raises an exception" do
        expect { backend.publish_record(DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with an A record" do
      it "upserts the A record" do
        expect(az_client.record_sets).to receive(:create_or_update).with(
                                           rg,
                                           zone,
                                           "flingle",
                                           "A",
                                           match_azure_record(
                                             "properties" => { "TTL" => 42, "ARecords" => [{ "ipv4Address" => "192.0.2.42" }] }))
        expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("flingle", 42, :A, "192.0.2.42"))
      end
    end

    context "with a AAAA record" do
      it "upserts the AAAA record" do
        expect(az_client.record_sets).to receive(:create_or_update).with(
                                           rg,
                                           zone,
                                           "flingle",
                                           "AAAA",
                                           match_azure_record(
                                             "properties" => { "TTL" => 42, "AAAARecords" => [{ "ipv6Address" => "2001:DB8::42" }] }))
        expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"))
      end
    end

    context "with a CNAME record" do
      it "upserts the CNAME record" do
        expect(az_client.record_sets).to receive(:create_or_update).with(
                                           rg,
                                           zone,
                                           "db",
                                           "CNAME",
                                           match_azure_record("properties" => { "TTL" => 42, "CNAMERecord" => { "cname" => "pgsql.host27.example.com" } }))
        expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("db", 42, :CNAME, "pgsql.host27"))
      end
    end

    context "with a TXT record" do
      it "upserts the TXT record" do
        expect(az_client.record_sets).to receive(:create_or_update).with(
                                           rg,
                                           zone,
                                           "faff._http._tcp",
                                           "TXT",
                                           match_azure_record("properties" => { "TTL" => 42, "TXTRecords" => [{ "value" => ["something \"funny\"", "this too"] }] }))
        expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :TXT, 'something "funny"', "this too"))
      end

      it "works around an azure limitation of blank records by upserting a TXT record with a space" do
        expect(az_client.record_sets).to receive(:create_or_update).with(rg, zone, "faff._http._tcp", "TXT", match_azure_record("properties" => { "TTL" => 42, "TXTRecords" => [{ "value" => [" "] }] }))
        expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :TXT, ""))
      end
    end

    context "with a SRV record" do
      context "no existing recordset" do
        it "creates a new SRV record" do
          expect(az_client.record_sets).to receive(:create_or_update).with(
                                             rg,
                                             zone,
                                             "faff._http._tcp",
                                             "SRV",
                                             match_azure_record(
                                               "properties" => { "TTL" => 42, "SRVRecords" => [{ "priority" => "0", "weight" => "0", "port" => "80", "target" => "faff.host22.example.com" }] }),
                                             if_none_match: "*")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
        end
      end

      context "with existing records for the name/type" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host1"),
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host3")
          )
        end

        #TODO better tests for this?
        it "adds a SRV record to the existing recordset" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "faff._http._tcp", "SRV", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
        end
      end

      #TODO better tests for this?
      context "with the record already existent" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host1"),
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host3"),
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22")
          )
        end

        #TODO better tests for this?
        it "makes sure we're up-to-date" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "faff._http._tcp", "SRV", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
        end
      end

      context "on error" do
        let(:refreshed_response) { azure_response_fixture("faff_response").first }

        context "with records added" do
          it "refreshes the zone data and retries the request with the new values" do
            expect(az_client.record_sets).to receive(:create_or_update).and_raise(MsRestAzure::AzureOperationError, "test").ordered
            expect(az_client.record_sets).to receive(:get).with(rg, zone, "faff._http._tcp", "SRV").and_return(refreshed_response).ordered

            expect(az_client.record_sets).to receive(:update).with(rg, zone, "faff._http._tcp", "SRV", anything, if_match: "faff_etag").and_return(OpenStruct.new(etag: "other")).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
          end
        end

        context "with records removed" do
          it "refreshes the zone data and retries the request with the new values" do
            expect(az_client.record_sets).to receive(:create_or_update).and_raise(MsRestAzure::AzureOperationError, "test").ordered
            expect(az_client.record_sets).to receive(:get).with(rg, zone, "faff._http._tcp", "SRV").and_raise(MsRestAzure::AzureOperationError, "404 doesn't exist").ordered

            expect(az_client.record_sets).to receive(:create_or_update).with(rg, zone, "faff._http._tcp", "SRV", anything, if_none_match: "*").and_return(OpenStruct.new(etag: "other")).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
          end
        end

        context "and never resolving" do

          it "retries for a while then gives up" do
            expect(az_client.record_sets).to receive(:create_or_update).and_raise(MsRestAzure::AzureOperationError, "test").ordered

            9.times do
              expect(az_client.record_sets).to receive(:get).with(rg, zone, "faff._http._tcp", "SRV").and_return(refreshed_response).ordered
              expect(az_client.record_sets).to receive(:update).and_raise(MsRestAzure::AzureOperationError, "test").ordered
            end

            expect(logger).to receive(:error)

            backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
          end
        end
      end
    end

    context "with a PTR record" do
      context "no existing recordset" do
        it "creates a new PTR record" do
          expect(az_client.record_sets).to receive(:create_or_update).with(rg, zone, "_http._tcp", "PTR", anything, if_none_match: "*")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
        end
      end

      context "with existing records for the name/type" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "xyzzy._http._tcp"),
            DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "argle._http._tcp")
          )
        end

        #TODO better tests for this
        it "adds a PTR record to the existing recordset" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "_http._tcp", "PTR", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
        end
      end

      context "including the one we want to add" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp")
          )
        end

        it "runs a no-change change to ensure everything's up-to-date" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "_http._tcp", "PTR", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
        end
      end

      context "on error" do
        let(:refreshed_response) { azure_response_fixture("http_ptr_response").first }

        context "with records added" do
          it "refreshes the zone data and retries the request with the new values" do
            expect(az_client.record_sets).to receive(:create_or_update).and_raise(MsRestAzure::AzureOperationError, "test").ordered
            expect(az_client.record_sets).to receive(:get).with(rg, zone, "_http._tcp", "PTR").and_return(refreshed_response).ordered

            expect(az_client.record_sets).to receive(:update).with(rg, zone, "_http._tcp", "PTR", anything, if_match: "http_ptr_etag").and_return(OpenStruct.new(etag: "other")).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
          end
        end

        context "with records removed" do
          it "refreshes the zone data and retries the request with the new values" do
            expect(az_client.record_sets).to receive(:create_or_update).and_raise(MsRestAzure::AzureOperationError, "test").ordered
            expect(az_client.record_sets).to receive(:get).with(rg, zone, "_http._tcp", "PTR").and_raise(MsRestAzure::AzureOperationError, "404 doesn't exist").ordered

            expect(az_client.record_sets).to receive(:create_or_update).with(rg, zone, "_http._tcp", "PTR", anything, if_none_match: "*").and_return(OpenStruct.new(etag: "other")).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
          end
        end

        context "and never resolving" do

          it "retries for a while then gives up" do
            expect(az_client.record_sets).to receive(:create_or_update).and_raise(MsRestAzure::AzureOperationError, "test").ordered

            9.times do
              expect(az_client.record_sets).to receive(:get).with(rg, zone, "_http._tcp", "PTR").and_return(refreshed_response).ordered
              expect(az_client.record_sets).to receive(:update).and_raise(MsRestAzure::AzureOperationError, "test").ordered
            end

            expect(logger).to receive(:error)

            backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
          end
        end
      end
    end
  end

  describe "#suppress_record" do
    before(:each) do

      allow(az_client.record_sets).to receive(:create).and_return(OpenStruct.new(etag: "1"))
      allow(az_client.record_sets).to receive(:update).and_return(OpenStruct.new(etag: "1"))
      allow(az_client.record_sets).to receive(:create_or_update).and_return(OpenStruct.new(etag: "1"))
      allow(az_client.record_sets).to receive(:delete)
    end
    context "with an A record" do
      context "with no other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42")
          )
        end

        it "deletes the record set" do
          expect(az_client.record_sets).to receive(:delete).with(rg, zone, "abcd1234.flingle", "A", if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
        end
      end

      context "with other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.1"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.180")
          )
        end

        # TODO - better tests
        it "modifies the record set to remove our record" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "abcd1234.flingle", "A", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)
          expect(az_client.record_sets).to_not receive(:delete)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
        end
      end

      # TODO - better tests
      context "with our record already gone" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.1"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.180")
          )
        end

        it "makes a no-op request to make sure everything is up-to-date" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "abcd1234.flingle", "A", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)
          expect(az_client.record_sets).to_not receive(:delete)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
        end
      end
    end

    context "with a AAAA record" do
      context "with no other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42")
          )
        end

        it "deletes the record set" do
          expect(az_client.record_sets).to receive(:delete).with(rg, zone, "flingle", "AAAA", if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"))
        end
      end

      context "with other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::1"),
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"),
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::180")
          )
        end

        # TODO - better tests
        it "modifies the record set to remove our record" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "flingle", "AAAA", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)
          expect(az_client.record_sets).to_not receive(:delete)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"))
        end
      end

      context "with our record already gone" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::1"),
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::180")
          )
        end

        # TODO - better tests
        it "makes a no-op request to make sure everything is up-to-date" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "flingle", "AAAA", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)
          expect(az_client.record_sets).to_not receive(:delete)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"))
        end
      end
    end

    context "with a CNAME record" do
      context "with no other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42")
          )
        end

        it "deletes the record set" do
          expect(az_client.record_sets).to receive(:delete).with(rg, zone, "flingle", "CNAME", if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42"))
        end
      end

      context "with other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host1"),
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42"),
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host180")
          )
        end

        #TODO better tests...
        it "modifies the record set to remove our record" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "flingle", "CNAME", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)
          expect(az_client.record_sets).to_not receive(:delete)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42"))
        end
      end

      context "with our record already gone" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host1"),
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host180")
          )
        end

        it "makes a no-op request to make sure everything is up-to-date" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "flingle", "CNAME", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)
          expect(az_client.record_sets).to_not receive(:delete)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42"))
        end
      end
    end

    context "with a SRV record" do
      context "with other SRV records present" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host1"),
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host2")
          )
        end

        #TODO better tests
        it "deletes our SRV record from the record set" do
          expect(az_client.record_sets).to receive(:update).with(rg, zone, "faff._http._tcp", "SRV", anything, if_match: "etag")
          expect(az_client.record_sets).to_not receive(:list_resource_record_sets)
          expect(az_client.record_sets).to_not receive(:delete)

          backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host2"))
        end

      end

      context "with no other SRV records present" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host1")
          )
          backend.instance_variable_get(:@record_cache).set(
            "etag",
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :TXT, "something funny")
          )
        end

        context "with no other PTR records" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              "etag",
              DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp")
            )
          end

          it "deletes the SRV, TXT, and PTR record sets" do
            expect(az_client.record_sets).to receive(:delete).with(rg, zone, "faff._http._tcp", "SRV", if_match: "etag")
            expect(az_client.record_sets).to receive(:delete).with(rg, zone, "_http._tcp", "PTR", if_match: "etag")
            expect(az_client.record_sets).to receive(:delete).with(rg, zone, "faff._http._tcp", "TXT", if_match: "etag")
            expect(az_client.record_sets).to_not receive(:list_resource_record_sets)

            backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host1"))
          end
        end

        context "with other PTR records" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              "etag",
              DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "blargh._http._tcp"),
              DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp")
            )
          end

          it "deletes the SRV and TXT record sets, and prunes our record from the PTR record set" do
            expect(az_client.record_sets).to receive(:delete).with(rg, zone, "faff._http._tcp", "SRV", if_match: "etag")
            expect(az_client.record_sets).to receive(:delete).with(rg, zone, "faff._http._tcp", "TXT", if_match: "etag")
            expect(az_client.record_sets).to receive(:update).with(rg, zone, "_http._tcp", "PTR", anything, if_match: "etag")
            expect(az_client.record_sets).to_not receive(:list_resource_record_sets)
            expect(az_client.record_sets).to_not receive(:delete).with(rg, zone, "_http._tcp", "PTR", if_match: "etag")

            backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host1"))
          end
        end
      end
    end

    context "with a TXT record" do
      it "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("x", 60, :TXT, "")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with a PTR record" do
      it "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("x", 60, :PTR, "faff")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with an NS record" do
      it "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

  end
end

# frozen_string_literal: true
require_relative './spec_helper'

require 'ddnssd/backend'
require 'ddnssd/config'
require 'ddnssd/dns_record'

describe DDNSSD::Backend do
  uses_logger

  let(:mock_config) { instance_double(DDNSSD::Config) }
  let(:backend) { DDNSSD::Backend.new(mock_config) }

  before(:each) do
    allow(mock_config).to receive(:logger).and_return(logger)
    allow(mock_config).to receive(:metrics_registry).and_return(Prometheus::Client::Registry.new)
    allow(mock_config).to receive(:backend_configs).and_return("backend" => {})
  end

  describe "#publish_record" do
    before(:each) do
      allow(backend).to receive(:base_domain).and_return(Resolv::DNS::Name.create("example.com."))
    end

    it "calls set_record for an A record" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :A, "192.0.2.42")

      expect(backend).to receive(:set_record).with(rr)
      backend.publish_record(rr)
    end

    it "calls set_record for a AAAA record" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :AAAA, "2001:db8::42")

      expect(backend).to receive(:set_record).with(rr)
      backend.publish_record(rr)
    end

    it "calls set_record for a TXT record" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :TXT, "ohai")

      expect(backend).to receive(:set_record).with(rr)
      backend.publish_record(rr)
    end

    it "calls set_record for a CNAME record" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :CNAME, "bar")

      expect(backend).to receive(:set_record).with(rr)
      backend.publish_record(rr)
    end

    it "calls add_record for a SRV record" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :SRV, 0, 0, 8080, "bar")

      expect(backend).to receive(:add_record).with(rr)
      backend.publish_record(rr)
    end

    it "calls add_record for a PTR record" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :PTR, "bar")

      expect(backend).to receive(:add_record).with(rr)
      backend.publish_record(rr)
    end
  end

  describe "#suppress_record" do
    before(:each) do
      allow(backend).to receive(:base_domain).and_return(Resolv::DNS::Name.create("example.com."))
    end

    it "calls remove_record on a per-container IPv4 address" do
      rr = DDNSSD::DNSRecord.new("abcd1234.foo", 60, :A, "172.17.0.42")

      expect(backend).to receive(:remove_record).with(rr)
      backend.suppress_record(rr)
    end

    it "does not call remove_record on the host's IPv4 address" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :A, "192.0.2.42")

      expect(backend).to_not receive(:remove_record).with(rr)
      backend.suppress_record(rr)
    end

    it "does not call remove_record on an IP address record" do
      rr = DDNSSD::DNSRecord.new("192-0-2-42.foo", 60, :A, "192.0.2.42")

      expect(backend).to_not receive(:remove_record).with(rr)
      backend.suppress_record(rr)
    end

    it "calls remove_record on an IPv6 address" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :AAAA, "2001:db8::42")

      expect(backend).to receive(:remove_record).with(rr)
      backend.suppress_record(rr)
    end

    it "calls remove_record on a CNAME" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :CNAME, "bar.example.com")

      expect(backend).to receive(:remove_record).with(rr)
      backend.suppress_record(rr)
    end

    it "calls remove_srv_record on a SRV" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :SRV, 0, 0, 8080, "bar")

      expect(backend).to receive(:remove_srv_record).with(rr)
      backend.suppress_record(rr)
    end

    it "refuses to deal with a TXT record" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :TXT, "ohai")

      expect { backend.suppress_record(rr) }.to raise_error(DDNSSD::Backend::InvalidRequest)
    end

    it "refuses to deal with a PTR record" do
      rr = DDNSSD::DNSRecord.new("foo", 60, :PTR, "bar")

      expect { backend.suppress_record(rr) }.to raise_error(DDNSSD::Backend::InvalidRequest)
    end
  end

  describe "#suppress_shared_records" do
    before(:each) do
      allow(mock_config).to receive(:host_dns_record).and_return(DDNSSD::DNSRecord.new("foo", 60, :A, "192.0.2.42"))
      allow(backend).to receive(:base_domain).and_return(Resolv::DNS::Name.create("example.com."))
    end

    it "calls remove_record on the host's IPv4 address" do
      host_rr = DDNSSD::DNSRecord.new("foo", 60, :A, "192.0.2.42")

      expect(mock_config).to receive(:host_dns_record).and_return(host_rr)
      expect(backend).to receive(:suppress_record).with(host_rr)
      backend.suppress_shared_records
    end

    it "calls remove_record on a shared IP address record when removal was previously attempted" do
      rr = DDNSSD::DNSRecord.new("192-0-2-42.foo", 60, :A, "192.0.2.42")

      expect(backend).to receive(:remove_record).with(rr)
      backend.suppress_record(rr)
      backend.suppress_shared_records
    end
  end

  context "#base_domain" do
    context "with no backend-specific config" do
      it "gets the base domain from the system config" do
        expect(mock_config).to receive(:base_domain).and_return("example.com")

        base_domain = backend.__send__(:base_domain)
        expect(base_domain.to_s).to eq("example.com")
        expect(base_domain).to be_a(Resolv::DNS::Name)
      end
    end

    context "with a backend-specific base domain" do
      it "uses the backend-specific base domain" do
        expect(mock_config)
          .to receive(:backend_configs)
          .and_return("backend" => { "BASE_DOMAIN" => "example.net" })
        expect(mock_config).to_not receive(:base_domain)

        base_domain = backend.__send__(:base_domain)
        expect(base_domain.to_s).to eq("example.net")
        expect(base_domain).to be_a(Resolv::DNS::Name)
      end
    end
  end
end

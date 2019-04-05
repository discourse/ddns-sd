require_relative './spec_helper'

require 'ddnssd/config'
require 'ddnssd/container'
require 'ddnssd/service_instance'

describe DDNSSD::Container do
  uses_logger

  let(:env) do
    {
      "DDNSSD_HOSTNAME"        => "speccy",
      "DDNSSD_BACKEND"         => "test_queue",
      "DDNSSD_BASE_DOMAIN"     => "example.com",
      "DDNSSD_HOST_IP_ADDRESS" => "192.0.2.42"
    }
  end

  let(:config) { DDNSSD::Config.new(env, logger: logger) }

  let(:docker_data) { container_fixture(container_name) }

  let(:container) { DDNSSD::Container.new(docker_data, config) }

  context "basic container data" do
    let(:container_name) { "basic_container" }

    describe "#id" do
      it "returns the full ID" do
        expect(container.id).to eq("asdfasdfbasiccontainer")
      end
    end

    describe "#short_id" do
      it "returns a truncated ID" do
        expect(container.short_id).to eq("asdfasdfbasi")
      end
    end

    describe "#ipv4_address" do
      it "extracts the container's IPv4 address" do
        expect(container.ipv4_address).to eq("172.17.0.42")
      end
    end

    describe "#ipv6_address" do
      it "extracts the container's IPv6 address" do
        expect(container.ipv6_address).to eq("2001:db8::42")
      end
    end

    describe "#addressable?" do
      it "is true" do
        expect(container.addressable?).to be true
      end
    end

    describe "#dns_records" do
      it "returns no DNS records" do
        expect(container.dns_records).to be_empty
      end
    end

    describe "#port_exposed?" do
      it "has no ports exposed" do
        %w{80 22}.each { |p| expect(container.port_exposed?("#{p}/tcp")).to be(false) }
      end
    end

    describe "#host_port_for" do
      it "has no port mappings" do
        %w{80 22}.each { |p| expect(container.host_port_for("#{p}/tcp")).to be(nil) }
      end
    end

    describe "#host_address_for" do
      it "has no address mappings" do
        %w{80 22}.each { |p| expect(container.host_address_for("#{p}/tcp")).to be(nil) }
      end
    end
  end

  context "container with no networks" do
    let(:container_name) { "no_network" }

    before(:each) do
      allow(logger).to receive(:error)
    end

    it "doesn't log an error" do
      container

      expect(logger).to_not have_received(:error)
    end

    it "doesn't return an IPv4 address" do
      expect(container.ipv4_address).to eq(nil)
    end

    it "doesn't return an IPv6 address" do
      expect(container.ipv6_address).to eq(nil)
    end

    it "is not addressable" do
      expect(container.addressable?).to be(false)
    end
  end

  context "container with two networks" do
    let(:container_name) { "multi_network" }

    before(:each) do
      allow(logger).to receive(:error)
    end

    it "logs an error" do
      container

      expect(logger).to have_received(:error)
    end

    it "doesn't return an IPv4 address" do
      expect(container.ipv4_address).to eq(nil)
    end

    it "doesn't return an IPv6 address" do
      expect(container.ipv6_address).to eq(nil)
    end
  end

  context "net host with exposed port 80" do
    let(:container_name) { "host_port80" }

    describe "#port_exposed?" do
      it "lists the port as exposed" do
        expect(container.port_exposed?("80/tcp")).to be(true)
      end
    end

    describe "#host_port_for" do
      it "just echos any host for" do
        expect(container.host_port_for("666/tcp")).to be(666)
      end
    end

    describe "#dns_records" do
      it "returns a correct DNS record set" do
        expect(container.dns_records).to eq(dns_record_fixtures("host_port80"))
      end
    end
  end

  context "exposed-port container with single label set" do
    let(:container_name) { "exposed_port80" }

    describe "#port_exposed?" do
      it "lists the port as exposed" do
        expect(container.port_exposed?("80/tcp")).to be(true)
      end
    end

    describe "#host_port_for" do
      it "has no port mapping for the exposed port" do
        expect(container.host_port_for("80/tcp")).to be(nil)
      end
    end

    describe "#host_address_for" do
      it "has no address mapping for the exposed port" do
        expect(container.host_address_for("80/tcp")).to be(nil)
      end
    end

    describe "#dns_records" do
      it "returns a DNS record set" do
        expect(container.dns_records).to eq(dns_record_fixtures("exposed_port80"))
      end
    end
  end

  context "published-port container with label set" do
    let(:container_name) { "published_port80" }

    describe "#port_exposed?" do
      it "lists the port as exposed" do
        expect(container.port_exposed?("80/tcp")).to be(true)
      end
    end

    describe "#host_port_for" do
      it "has a port mapping for 80/tcp" do
        expect(container.host_port_for("80/tcp")).to eq("8080")
      end
    end

    describe "#host_address_for" do
      it "has no address mapping for 80/tcp" do
        expect(container.host_address_for("80/tcp")).to be(nil)
      end
    end

    describe "#dns_records" do
      it "returns a DNS record set" do
        expect(container.dns_records).to eq(dns_record_fixtures("published_port80"))
      end
    end
  end

  context "exposed-port container with multiple instances of the same service" do
    let(:container_name) { "exposed_port_multiple_instances" }

    describe "#dns_records" do
      it "returns a DNS record set" do
        expect(container.dns_records).to eq(dns_record_fixtures("exposed_port_multiple_instances"))
      end
    end
  end

  context "published-port container with no labels" do
    let(:container_name) { "published_port22" }

    describe "#port_exposed?" do
      it "lists the port as exposed" do
        expect(container.port_exposed?("22/tcp")).to be(true)
      end
    end

    describe "#host_port_for" do
      it "has a port mapping for 22/tcp" do
        expect(container.host_port_for("22/tcp")).to eq("2222")
      end
    end

    describe "#host_address_for" do
      it "has no address mapping for 22/tcp" do
        expect(container.host_address_for("22/tcp")).to be(nil)
      end
    end

    describe "#dns_records" do
      it "returns no DNS records" do
        expect(container.dns_records).to be_empty
      end
    end
  end

  context "published-port container with specified IP address" do
    let(:docker_data) do
      container_fixture("published_port80").tap do |dd|
        dd.info["NetworkSettings"]["Ports"]["80/tcp"].first["HostIp"] = "192.0.2.222"
      end
    end

    describe "#host_address_for" do
      it "has an address mapping for 80/tcp" do
        expect(container.host_address_for("80/tcp")).to eq("192.0.2.222")
      end
    end
  end

  context "published-port container with buggy label" do
    let(:docker_data) do
      container_fixture("published_port80").tap do |dd|
        dd.info["Config"]["Labels"] = { "org.discourse.service.flibbety.port" => "80" }
      end
    end

    before(:each) { allow(logger).to receive(:warn) }

    describe "#dns_records" do
      it "returns no records" do
        expect(container.dns_records).to be_empty
      end

      it "logs a warning" do
        expect(logger).to receive(:warn)

        container.dns_records
      end
    end
  end

  context "stopped container" do
    let(:docker_data) { container_fixture("stopped_container") }

    describe "#addressable?" do
      it "is false" do
        expect(container.addressable?).to be false
      end
    end
  end

  describe "#publish_records" do
    let(:mock_backend) { instance_double(DDNSSD::Backend) }

    it "doesn't do anything interesting without services" do
      expect(mock_backend).to_not receive(:publish_record)

      DDNSSD::Container.new(container_fixture("basic_container"), config).publish_records(mock_backend)
    end

    it "publishes records if the container has them" do
      dns_record_fixture("published_port80").each do |rr|
        expect(mock_backend).to receive(:publish_record).with(rr)
      end

      DDNSSD::Container.new(container_fixture("published_port80"), config).publish_records(mock_backend)
    end
  end

  describe "#suppress_records" do
    let(:mock_backend) { instance_double(DDNSSD::Backend) }

    it "doesn't do anything interesting without services" do
      expect(mock_backend).to_not receive(:suppress_record)

      DDNSSD::Container.new(container_fixture("basic_container"), config).suppress_records(mock_backend)
    end

    it "suppresses records if the container has them" do
      dns_record_fixture("published_port80").each do |rr|
        expect(mock_backend).to receive(:suppress_record).with(rr) unless %i{TXT PTR}.include?(rr.type)
      end

      DDNSSD::Container.new(container_fixture("published_port80"), config).suppress_records(mock_backend)
    end
  end
end

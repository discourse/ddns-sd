# frozen_string_literal: true
require_relative './spec_helper'

require 'ddnssd/config'

describe DDNSSD::Config do
  uses_logger

  let(:base_env) do
    {
      "DDNSSD_HOSTNAME"    => "speccy",
      "DDNSSD_BASE_DOMAIN" => "example.com",
      "DDNSSD_BACKEND"     => "test_queue"
    }
  end
  # Work around problem where you can't reference the same let in a nested
  # scope any more without ending up in a recursive hellscape.
  let(:env) { base_env }

  let(:config) { DDNSSD::Config.new(env, logger: logger) }

  describe ".new" do
    it "creates a config object" do
      expect(config).to be_a(DDNSSD::Config)
    end

    it "accepts our logger" do
      expect(config.logger).to eq(logger)
    end

    context "DDNSSD_HOSTNAME" do
      it "freaks out without it" do
        expect { DDNSSD::Config.new(env.reject { |k| k == "DDNSSD_HOSTNAME" }, logger: logger) }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end

      it "freaks out if it's empty" do
        expect { DDNSSD::Config.new(env.merge("DDNSSD_HOSTNAME" => ""), logger: logger) }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end

      it "freaks out if it isn't hostnameish" do
        expect { DDNSSD::Config.new(env.merge("DDNSSD_HOSTNAME" => "ohai!"), logger: logger) }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end

      it "is OK with something hostnameish" do
        expect(config.hostname).to eq("speccy")
      end
    end

    context "DDNSSD_BASE_DOMAIN" do
      it "freaks out without it" do
        expect { DDNSSD::Config.new(env.reject { |k| k == "DDNSSD_BASE_DOMAIN" }, logger: logger) }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end

      it "freaks out if it's empty" do
        expect { DDNSSD::Config.new(env.merge("DDNSSD_BASE_DOMAIN" => ""), logger: logger) }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end

      it "freaks out if it isn't fqdnish" do
        expect { DDNSSD::Config.new(env.merge("DDNSSD_BASE_DOMAIN" => "ohai!"), logger: logger) }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end

      it "is OK with something fqdnish" do
        expect(config.base_domain).to eq("example.com")
      end
    end

    context "DDNSSD_BACKEND" do
      it "accepts our test backend" do
        expect(config.backend_classes).to eq([DDNSSD::Backend::TestQueue])
      end

      context "with multiple comma-separated backend names" do
        let(:env) do
          base_env.merge("DDNSSD_BACKEND" => "test_queue,log", "DDNSSD_LOG_FAFF" => "hooboy")
        end

        it "handles multiple backends" do
          expect(config.backend_classes).to eq([DDNSSD::Backend::TestQueue, DDNSSD::Backend::Log])
        end

        it "has the extra backend's config" do
          expect(config.backend_configs["log"]).to eq("FAFF" => "hooboy")
        end
      end

      it "freaks out without it" do
        expect { DDNSSD::Config.new(env.reject { |k| k == "DDNSSD_BACKEND" }, logger: logger) }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end

      it "freaks out if it's empty" do
        expect { DDNSSD::Config.new(env.merge("DDNSSD_BACKEND" => ""), logger: logger) }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end

      it "freaks out if it isn't a known backend" do
        expect { DDNSSD::Config.new(env.merge("DDNSSD_BACKEND" => "a_mystery"), logger: logger) }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end
    end

    context "DDNSSD_TEST_QUEUE_*" do
      let(:env) do
        base_env.merge("DDNSSD_TEST_QUEUE_FOO" => "bar", "DDNSSD_TEST_QUEUE_BAZ" => "wombat")
      end

      it "extracts additional env vars for the backend" do
        expect(config.backend_configs).to eq("test_queue" => { "FOO" => "bar", "BAZ" => "wombat" })
      end
    end

    context "DDNSSD_IPV6_ONLY" do
      let(:value) { config.ipv6_only }

      context "with an empty string" do
        let(:env) { base_env.merge("DDNSSD_IPV6_ONLY" => "") }

        it "is false" do
          expect(value).to eq(false)
        end
      end

      %w{on yes 1 true}.each do |s|
        context "with true-ish value #{s}" do
          let(:env) { base_env.merge("DDNSSD_IPV6_ONLY" => s) }

          it "is true" do
            expect(value).to eq(true)
          end
        end
      end

      %w{off no 0 false}.each do |s|
        context "with false-y value #{s}" do
          let(:env) { base_env.merge("DDNSSD_IPV6_ONLY" => s) }

          it "is false" do
            expect(value).to eq(false)
          end
        end
      end

      context "with other values" do
        let(:env) { base_env.merge("DDNSSD_IPV6_ONLY" => "ermahgerd") }

        it "freaks out" do
          expect { config }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end
    end

    context "DDNSSD_ENABLE_METRICS" do
      let(:value) { config.enable_metrics }

      context "with an empty string" do
        let(:env) { base_env.merge("DDNSSD_ENABLE_METRICS" => "") }

        it "is false" do
          expect(value).to eq(false)
        end
      end

      %w{on yes 1 true}.each do |s|
        context "with true-ish value #{s}" do
          let(:env) { base_env.merge("DDNSSD_ENABLE_METRICS" => s) }

          it "is true" do
            expect(value).to eq(true)
          end
        end
      end

      %w{off no 0 false}.each do |s|
        context "with false-y value #{s}" do
          let(:env) { base_env.merge("DDNSSD_ENABLE_METRICS" => s) }

          it "is false" do
            expect(value).to eq(false)
          end
        end
      end

      context "with other values" do
        let(:env) { base_env.merge("DDNSSD_ENABLE_METRICS" => "ermahgerd") }

        it "freaks out" do
          expect { config }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end
    end

    context "DDNSSD_RECORD_TTL" do
      let(:value) { config.record_ttl }

      context "with an empty string" do
        let(:env) { base_env.merge("DDNSSD_RECORD_TTL" => "") }

        it "is the default of 60" do
          expect(value).to eq(60)
        end
      end

      context "with a reasonable number" do
        let(:env) { base_env.merge("DDNSSD_RECORD_TTL" => "360") }

        it "is OK" do
          expect(value).to eq(360)
        end
      end

      context "with a negative number" do
        let(:env) { base_env.merge("DDNSSD_RECORD_TTL" => "-360") }

        it "freaks out" do
          expect { config }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end

      context "with a HUEG number" do
        let(:env) { base_env.merge("DDNSSD_RECORD_TTL" => (2**48).to_s) }

        it "freaks out" do
          expect { config }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end

      context "with some gibberish string" do
        let(:env) { base_env.merge("DDNSSD_RECORD_TTL" => "ermahgerd") }

        it "freaks out" do
          expect { config }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end
    end

    context "DDNSSD_HOST_IP_ADDRESS" do
      let(:value) { config.host_ip_address }

      context "with an empty string" do
        let(:env) { base_env.merge("DDNSSD_HOST_IP_ADDRESS" => "") }

        it "is nil" do
          expect(value).to be(nil)
        end
      end

      context "with an IPv4 address" do
        let(:env) { base_env.merge("DDNSSD_HOST_IP_ADDRESS" => "192.0.2.42") }

        it "is OK" do
          expect(value).to be_a(String)
          expect(value).to eq("192.0.2.42")
        end
      end

      context "with an IPv6 address" do
        let(:env) { base_env.merge("DDNSSD_HOST_IP_ADDRESS" => "2001:db8::42") }

        it "freaks out" do
          expect { config }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end

      context "with an IPv6 address and DDNSSD_IPV6_ONLY is enabled" do
        let(:env) { base_env.merge(
          "DDNSSD_HOST_IP_ADDRESS" => "2001:db8::42",
          "DDNSSD_IPV6_ONLY" => 'true'
        ) }

        it "is OK" do
          expect(value).to be_a(String)
          expect(value).to eq("2001:db8::42")
        end
      end

      context "with an IPv4 address and DDNSSD_IPV6_ONLY is enabled" do
        let(:env) { base_env.merge(
          "DDNSSD_HOST_IP_ADDRESS" => "192.0.2.42",
          "DDNSSD_IPV6_ONLY" => 'true'
        ) }

        it "freaks out" do
          expect { config }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end

      context "with some gibberish string" do
        let(:env) { base_env.merge("DDNSSD_HOST_IP_ADDRESS" => "ermahgerd") }

        it "freaks out" do
          expect { config }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end
    end

    context "DOCKER_HOST" do
      let(:value) { config.docker_host }

      context "with an empty string" do
        let(:env) { base_env.merge("DOCKER_HOST" => "") }

        it "keeps the default" do
          expect(config.docker_host).to eq("unix:///var/run/docker.sock")
        end
      end

      context "with a custom value" do
        let(:env) { base_env.merge("DOCKER_HOST" => "tcp://192.0.2.42") }

        it "stores the alternate value" do
          expect(config.docker_host).to eq('tcp://192.0.2.42')
        end
      end
    end
  end

  describe "#host_dns_record" do
    it "is nil if there's no host IP address" do
      expect(config.host_dns_record).to be(nil)
    end

    context 'with host IP address' do
      let(:env) { base_env.merge("DDNSSD_HOST_IP_ADDRESS" => "192.0.2.42") }

      it 'is A record' do
        dns_record = config.host_dns_record
        expect(dns_record).to be_a(DDNSSD::DNSRecord)
        expect(dns_record.name).to eq(env['DDNSSD_HOSTNAME'])
        expect(dns_record.type).to eq(:A)
        expect(dns_record.value).to eq(env['DDNSSD_HOST_IP_ADDRESS'])
      end
    end

    context 'with host IP address and IPv6 only' do
      let(:env) { base_env.merge("DDNSSD_HOST_IP_ADDRESS" => "2001:db8::42", "DDNSSD_IPV6_ONLY" => "true") }

      it 'is AAAA record' do
        dns_record = config.host_dns_record
        expect(dns_record).to be_a(DDNSSD::DNSRecord)
        expect(dns_record.name).to eq(env['DDNSSD_HOSTNAME'])
        expect(dns_record.type).to eq(:AAAA)
        expect(dns_record.value).to eq('2001:DB8::42')
      end
    end
  end
end

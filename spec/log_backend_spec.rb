# frozen_string_literal: true
require_relative './spec_helper'

require 'ddnssd/backend/log'

describe DDNSSD::Backend::Log do
  uses_logger

  let(:base_env) do
    {
      "DDNSSD_HOSTNAME"        => "speccy",
      "DDNSSD_BACKEND"         => "log",
      "DDNSSD_BASE_DOMAIN"     => "example.com",
    }
  end
  let(:env) { base_env }
  let(:config) { DDNSSD::Config.new(env, logger: logger) }

  let(:backend) { DDNSSD::Backend::Log.new(config) }

  describe "#dns_records" do
    it "always returns an empty list" do
      expect(backend.dns_records).to eq([])
    end
  end

  describe "#publish_record" do
    it "logs the publish call" do
      expect(logger).to receive(:info) { |_, &blk| expect(blk.call).to match(/publish.*flingle/i) }

      backend.publish_record(DDNSSD::DNSRecord.new("flingle", 42, :A, "192.0.2.42"))
    end
  end

  describe "#suppress_record" do
    it "logs the suppress call" do
      expect(logger).to receive(:info) { |_, &blk| expect(blk.call).to match(/suppress.*abcd1234.flingle/i) }

      backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
    end
  end
end

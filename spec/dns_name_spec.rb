# frozen_string_literal: true
require 'freedom_patches/dns_name'

describe Resolv::DNS::Name do
  describe "+" do
    it "adds two relative names and creates a relative name" do
      sum = Resolv::DNS::Name.create('foo') + Resolv::DNS::Name.create('bar')
      expect(sum.to_s).to eq('foo.bar')
      expect(sum).to_not be_absolute
    end

    it "adds relative to absolute and creates an absolute name" do
      sum = Resolv::DNS::Name.create('foo') + Resolv::DNS::Name.create('bar.com.')
      expect(sum.to_s).to eq('foo.bar.com')
      expect(sum).to be_absolute
    end

    it "raises error when adding absolute to relative" do
      expect {
        Resolv::DNS::Name.create('bar.com.') + Resolv::DNS::Name.create('foo')
      }.to raise_error(ArgumentError)
    end

    it "raises error when adding absolute to absolute" do
      expect {
        Resolv::DNS::Name.create('bar.com.') + Resolv::DNS::Name.create('foo.com.')
      }.to raise_error(ArgumentError)
    end
  end

  describe "-" do
    it "subtracts two relative names and creates a relative name" do
      diff = Resolv::DNS::Name.create('foo.bar') - Resolv::DNS::Name.create('bar')
      expect(diff.to_s).to eq('foo')
      expect(diff).to_not be_absolute
    end

    it "subtracts absolute name from an absolute name to create a relative name" do
      diff = Resolv::DNS::Name.create('foo.bar.com.') - Resolv::DNS::Name.create('bar.com.')
      expect(diff.to_s).to eq('foo')
      expect(diff).to_not be_absolute
    end

    it "raises an error when subtracting relative from absolute name" do
      expect {
        Resolv::DNS::Name.create('foo.bar.com.') - Resolv::DNS::Name.create('com')
      }.to raise_error(ArgumentError)
    end

    it "raises an error when subtracting absolute from relative name" do
      expect {
        Resolv::DNS::Name.create('foo.bar.com') - Resolv::DNS::Name.create('bar.com.')
      }.to raise_error(ArgumentError)
    end

    it "raises error if not a subdomain of what's being subtracted" do
      expect {
        Resolv::DNS::Name.create('foo.bar.com.') - Resolv::DNS::Name.create('baz.com.')
      }.to raise_error(ArgumentError)
    end

    it "subtracts from the end" do
      diff = Resolv::DNS::Name.create('my-server._tcp.my-server.example.com.') -
        Resolv::DNS::Name.create('my-server.example.com.')
      expect(diff.to_s).to eq('my-server._tcp')
    end
  end
end

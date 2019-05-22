# frozen_string_literal: true
require_relative './spec_helper'

require 'ddnssd/dns_record'

describe DDNSSD::DNSRecord do
  let(:abs_record) { DDNSSD::DNSRecord.new("foo.example.com.", 42, :A, "192.0.2.42") }
  let(:rel_record) { DDNSSD::DNSRecord.new("foo", 42, :A, "192.0.2.42") }
  let(:record) { abs_record }

  describe "#name" do
    context 'absolute' do
      it "returns the record's name" do
        expect(record.name).to eq("foo.example.com")
      end

      context "when passed a Resolv::DNS::Name" do
        let(:record) { DDNSSD::DNSRecord.new(Resolv::DNS::Name.create("foo.example.com"), 42, :A, "192.0.2.42") }

        it "returns the string name" do
          expect(record.name).to eq("foo.example.com")
        end
      end
    end
  end

  describe '#to_absolute' do
    let(:base_domain) { Resolv::DNS::Name.create('example.com.') }

    it 'returns an absolute record unchanged' do
      expect(abs_record.to_absolute(base_domain)).to eq(abs_record)
    end

    it 'works on relative A record' do
      rr = DDNSSD::DNSRecord.new("foo", 42, :A, "192.0.2.42")
      relrr = rr.to_absolute(base_domain)
      expect(relrr.name).to eq("foo.example.com")
    end

    it 'works on relative AAAA record' do
      rr = DDNSSD::DNSRecord.new("foo", 42, :AAAA, "2001:db8::42")
      relrr = rr.to_absolute(base_domain)
      expect(relrr.name).to eq("foo.example.com")
    end

    it 'works on relative CNAME record' do
      rr = DDNSSD::DNSRecord.new("foo", 42, :CNAME, "host1")
      relrr = rr.to_absolute(base_domain)
      expect(relrr.name).to eq("foo.example.com")
      expect(relrr.data.name.to_s).to eq("host1.example.com")
    end

    it 'works on relative SRV record' do
      rr = DDNSSD::DNSRecord.new("bar._foo._tcp", 42, :SRV, 0, 0, 8080, "bar1")
      relrr = rr.to_absolute(base_domain)
      expect(relrr.name).to eq("bar._foo._tcp.example.com")
      expect(relrr.data.target.to_s).to eq("bar1.example.com")
    end

    it 'works on relative TXT record' do
      rr = DDNSSD::DNSRecord.new("bar._foo._tcp", 42, :TXT, "nobugs")
      relrr = rr.to_absolute(base_domain)
      expect(relrr.name).to eq("bar._foo._tcp.example.com")
      expect(relrr.data.data).to eq("nobugs")
    end

    it 'works on relative PTR record' do
      rr = DDNSSD::DNSRecord.new("_foo._tcp", 42, :PTR, "bar._foo._tcp")
      relrr = rr.to_absolute(base_domain)
      expect(relrr.name).to eq("_foo._tcp.example.com")
      expect(relrr.data.name.to_s).to eq("bar._foo._tcp.example.com")
    end

    it 'raises error on NS record' do
      expect {
        DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com").to_absolute(base_domain)
      }.to raise_error(RuntimeError)
    end
  end

  describe '#to_relative' do
    let(:base_domain) { Resolv::DNS::Name.create('example.com.') }

    it 'returns a relative record unchanged' do
      expect(rel_record.to_relative(base_domain)).to eq(rel_record)
    end

    it 'works on absolute A record' do
      rr = DDNSSD::DNSRecord.new("foo.example.com.", 42, :A, "192.0.2.42")
      relrr = rr.to_relative(base_domain)
      expect(relrr.name).to eq("foo")
    end

    it 'works on absolute AAAA record' do
      rr = DDNSSD::DNSRecord.new("foo.example.com.", 42, :AAAA, "2001:db8::42")
      relrr = rr.to_relative(base_domain)
      expect(relrr.name).to eq("foo")
    end

    it 'works on absolute CNAME record' do
      rr = DDNSSD::DNSRecord.new("foo.example.com.", 42, :CNAME, "host1.example.com.")
      relrr = rr.to_relative(base_domain)
      expect(relrr.name).to eq("foo")
      expect(relrr.data.name.to_s).to eq("host1")
    end

    it 'works on absolute SRV record' do
      rr = DDNSSD::DNSRecord.new("bar._foo._tcp.example.com.", 42, :SRV, 0, 0, 8080, "bar1.example.com.")
      relrr = rr.to_relative(base_domain)
      expect(relrr.name).to eq("bar._foo._tcp")
      expect(relrr.data.target.to_s).to eq("bar1")
    end

    it 'works on absolute TXT record' do
      rr = DDNSSD::DNSRecord.new("bar._foo._tcp.example.com.", 42, :TXT, "nobugs")
      relrr = rr.to_relative(base_domain)
      expect(relrr.name).to eq("bar._foo._tcp")
      expect(relrr.data.data).to eq("nobugs")
    end

    it 'works on absolute PTR record' do
      rr = DDNSSD::DNSRecord.new("_foo._tcp.example.com.", 42, :PTR, "bar._foo._tcp.example.com.")
      relrr = rr.to_relative(base_domain)
      expect(relrr.name).to eq("_foo._tcp")
      expect(relrr.data.name.to_s).to eq("bar._foo._tcp")
    end

    it 'raises error on NS record' do
      expect {
        DDNSSD::DNSRecord.new("example.com.", 60, :NS, "ns1.example.com.").to_relative(base_domain)
      }.to raise_error(RuntimeError)
    end

    it 'raises error if A record is not a subdomain of given base domain' do
      expect {
        DDNSSD::DNSRecord.new("foo.example.org.", 42, :A, "192.0.2.42").to_relative(base_domain)
      }.to raise_error(ArgumentError)
    end

    it 'raises error if AAAA record is not a subdomain of given base domain' do
      expect {
        DDNSSD::DNSRecord.new("foo.example.org.", 42, :AAAA, "2001:db8::42").to_relative(base_domain)
      }.to raise_error(ArgumentError)
    end

    it 'raises error if CNAME record is not a subdomain of given base domain' do
      expect {
        DDNSSD::DNSRecord.new("foo.example.org.", 42, :CNAME, "host1.example.org.").to_relative(base_domain)
      }.to raise_error(ArgumentError)
    end

    it 'raises error if CNAME record value is not a subdomain of given base domain' do
      expect {
        DDNSSD::DNSRecord.new("foo.example.com.", 42, :CNAME, "host1.example.org.").to_relative(base_domain)
      }.to raise_error(ArgumentError)
    end

    it 'raises error if SRV record is not a subdomain of given base domain' do
      expect {
        DDNSSD::DNSRecord.new("bar._foo._tcp.example.org.", 42, :SRV, 0, 0, 8080, "bar1.example.org.").to_relative(base_domain)
      }.to raise_error(ArgumentError)
    end

    it 'raises error if SRV record target is not a subdomain of given base domain' do
      expect {
        DDNSSD::DNSRecord.new("bar._foo._tcp.example.com.", 42, :SRV, 0, 0, 8080, "bar1.example.org.").to_relative(base_domain)
      }.to raise_error(ArgumentError)
    end

    it 'raises error if TXT record is not a subdomain of given base domain' do
      expect {
        DDNSSD::DNSRecord.new("bar._foo._tcp.example.org.", 42, :TXT, "nobugs").to_relative(base_domain)
      }.to raise_error(ArgumentError)
    end

    it 'raises error if PTR record is not a subdomain of given base domain' do
      expect {
        DDNSSD::DNSRecord.new("_foo._tcp.example.org.", 42, :PTR, "bar._foo._tcp.example.org.").to_relative(base_domain)
      }.to raise_error(ArgumentError)
    end

    it 'raises error if PTR record target is not a subdomain of given base domain' do
      expect {
        DDNSSD::DNSRecord.new("_foo._tcp.example.com.", 42, :PTR, "bar._foo._tcp.example.org.").to_relative(base_domain)
      }.to raise_error(ArgumentError)
    end
  end

  describe "#ttl" do
    it "returns the record's TTL" do
      expect(record.ttl).to eq(42)
    end
  end

  describe '#new' do
    context 'absolute records' do
      context "with an A record" do
        let(:record) { DDNSSD::DNSRecord.new("foo.example.com.", 42, :A, "192.0.2.42") }

        it "is absolute" do
          expect(record).to be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('foo.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::A)
          end

          it "holds the provided address" do
            expect(record.data.address.to_s).to eq("192.0.2.42")
          end
        end

        describe "#value" do
          it "returns the address" do
            expect(record.value).to eq("192.0.2.42")
          end
        end
      end

      context "with a AAAA record" do
        let(:record) { DDNSSD::DNSRecord.new("foo.example.com.", 42, :AAAA, "2001:db8::42") }

        it "is absolute" do
          expect(record).to be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('foo.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::AAAA)
          end

          it "holds the provided address" do
            expect(record.data.address.to_s).to eq("2001:DB8::42")
          end
        end

        describe "#value" do
          it "returns the address" do
            expect(record.value).to eq("2001:DB8::42")
          end
        end
      end

      context "with a SRV record" do
        let(:record) { DDNSSD::DNSRecord.new("_bar._foo._tcp.example.com.", 42, :SRV, 2, 4, 8, "bar.example.com.") }

        it "is absolute" do
          expect(record).to be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('_bar._foo._tcp.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::SRV)
          end

          it "holds the provided priority" do
            expect(record.data.priority).to eq(2)
          end

          it "holds the provided weight" do
            expect(record.data.weight).to eq(4)
          end

          it "holds the provided port" do
            expect(record.data.port).to eq(8)
          end

          it "holds the provided target" do
            expect(record.data.target.to_s).to eq("bar.example.com")
          end
        end

        describe "#value" do
          it "returns the consolidated record data" do
            expect(record.value).to eq("2 4 8 bar.example.com")
          end
        end
      end

      context "with a PTR record" do
        let(:record) { DDNSSD::DNSRecord.new("_foo._tcp.example.com.", 42, :PTR, "_bar._foo._tcp.example.com.") }

        it "is absolute" do
          expect(record).to be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('_foo._tcp.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::PTR)
          end

          it "holds the provided name" do
            expect(record.data.name.to_s).to eq("_bar._foo._tcp.example.com")
          end
        end

        describe "#value" do
          it "returns the target" do
            expect(record.value).to eq("_bar._foo._tcp.example.com")
          end
        end
      end

      context "with a TXT record" do
        let(:record) { DDNSSD::DNSRecord.new("_bar._foo._tcp.example.com.", 42, :TXT, 'something "funny"', "this too") }

        it "is absolute" do
          expect(record).to be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('_bar._foo._tcp.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::TXT)
          end

          it "holds the provided strings" do
            expect(record.data.strings).to eq(['something "funny"', "this too"])
          end
        end

        describe "#value" do
          it "returns the quoted strings" do
            expect(record.value).to eq('"something \"funny\"" "this too"')
          end
        end
      end

      context "with a CNAME record" do
        let(:record) { DDNSSD::DNSRecord.new("something.example.com.", 42, :CNAME, "guy-incognito.example.com.") }

        it "is absolute" do
          expect(record).to be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('something.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::CNAME)
          end

          it "holds the provided name" do
            expect(record.data.name.to_s).to eq("guy-incognito.example.com")
          end
        end

        describe "#value" do
          it "returns the target" do
            expect(record.value).to eq("guy-incognito.example.com")
          end
        end
      end

      context "with a mystery record" do
        let(:record) { DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com") }

        describe "#value" do
          it "raises an exception" do
            expect { record.value }.to raise_error(RuntimeError)
          end
        end
      end
    end

    context 'relative records' do
      context "with an A record" do
        let(:record) { DDNSSD::DNSRecord.new("foo.example.com", 42, :A, "192.0.2.42") }

        it "is relative" do
          expect(record).to_not be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('foo.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::A)
          end

          it "holds the provided address" do
            expect(record.data.address.to_s).to eq("192.0.2.42")
          end
        end

        describe "#value" do
          it "returns the address" do
            expect(record.value).to eq("192.0.2.42")
          end
        end
      end

      context "with a AAAA record" do
        let(:record) { DDNSSD::DNSRecord.new("foo.example.com", 42, :AAAA, "2001:db8::42") }

        it "is relative" do
          expect(record).to_not be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('foo.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::AAAA)
          end

          it "holds the provided address" do
            expect(record.data.address.to_s).to eq("2001:DB8::42")
          end
        end

        describe "#value" do
          it "returns the address" do
            expect(record.value).to eq("2001:DB8::42")
          end
        end
      end

      context "with a SRV record" do
        let(:record) { DDNSSD::DNSRecord.new("_bar._foo._tcp.example.com", 42, :SRV, 2, 4, 8, "bar.example.com") }

        it "is relative" do
          expect(record).to_not be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('_bar._foo._tcp.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::SRV)
          end

          it "holds the provided priority" do
            expect(record.data.priority).to eq(2)
          end

          it "holds the provided weight" do
            expect(record.data.weight).to eq(4)
          end

          it "holds the provided port" do
            expect(record.data.port).to eq(8)
          end

          it "holds the provided target" do
            expect(record.data.target.to_s).to eq("bar.example.com")
          end
        end

        describe "#value" do
          it "returns the consolidated record data" do
            expect(record.value).to eq("2 4 8 bar.example.com")
          end
        end
      end

      context "with a PTR record" do
        let(:record) { DDNSSD::DNSRecord.new("_foo._tcp.example.com", 42, :PTR, "_bar._foo._tcp.example.com") }

        it "is relative" do
          expect(record).to_not be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('_foo._tcp.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::PTR)
          end

          it "holds the provided name" do
            expect(record.data.name.to_s).to eq("_bar._foo._tcp.example.com")
          end
        end

        describe "#value" do
          it "returns the target" do
            expect(record.value).to eq("_bar._foo._tcp.example.com")
          end
        end
      end

      context "with a TXT record" do
        let(:record) { DDNSSD::DNSRecord.new("_bar._foo._tcp.example.com", 42, :TXT, 'something "funny"', "this too") }

        it "is relative" do
          expect(record).to_not be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('_bar._foo._tcp.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::TXT)
          end

          it "holds the provided strings" do
            expect(record.data.strings).to eq(['something "funny"', "this too"])
          end
        end

        describe "#value" do
          it "returns the quoted strings" do
            expect(record.value).to eq('"something \"funny\"" "this too"')
          end
        end
      end

      context "with a CNAME record" do
        let(:record) { DDNSSD::DNSRecord.new("something.example.com", 42, :CNAME, "guy-incognito.example.com") }

        it "is relative" do
          expect(record).to_not be_absolute
        end

        describe '#name' do
          it 'is the absolute name' do
            expect(record.name).to eq('something.example.com')
          end
        end

        describe "#data" do
          it "is the appropriate class" do
            expect(record.data).to be_a(Resolv::DNS::Resource::IN::CNAME)
          end

          it "holds the provided name" do
            expect(record.data.name.to_s).to eq("guy-incognito.example.com")
          end
        end

        describe "#value" do
          it "returns the target" do
            expect(record.value).to eq("guy-incognito.example.com")
          end
        end
      end

      context "with a mystery record" do
        let(:record) { DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com") }

        describe "#value" do
          it "raises an exception" do
            expect { record.value }.to raise_error(RuntimeError)
          end
        end
      end
    end
  end

  describe '#subdomain_of?' do
    let(:base_domain) { Resolv::DNS::Name.create('example.com.') }

    it 'raises an error on a relative record' do
      expect {
        DDNSSD::DNSRecord.new("_foo._tcp", 42, :PTR, "_bar._foo._tcp").subdomain_of?(base_domain)
      }.to raise_error(RuntimeError)
    end

    it "returns true on A record with that's a subdomain" do
      expect(DDNSSD::DNSRecord.new("foo.example.com.", 42, :A, "192.0.2.42").subdomain_of?(base_domain)).to eq(true)
    end

    it "returns false on A record that's not a subdomain" do
      expect(DDNSSD::DNSRecord.new("foo.freedom.com.", 42, :A, "192.0.2.42").subdomain_of?(base_domain)).to eq(false)
    end

    it "returns true on AAAA record with that's a subdomain" do
      expect(DDNSSD::DNSRecord.new("foo.example.com.", 42, :AAAA, "2001:db8::42").subdomain_of?(base_domain)).to eq(true)
    end

    it "returns false on AAAA record that's not a subdomain" do
      expect(DDNSSD::DNSRecord.new("foo.freedom.com.", 42, :AAAA, "2001:db8::42").subdomain_of?(base_domain)).to eq(false)
    end

    it "returns true on CNAME record with that's a subdomain" do
      expect(DDNSSD::DNSRecord.new("foo.example.com.", 42, :CNAME, "host1.example.com").subdomain_of?(base_domain)).to eq(true)
    end

    it "returns false on CNAME record that's not a subdomain" do
      expect(DDNSSD::DNSRecord.new("foo.freedom.com.", 42, :CNAME, "host1.freedom.com").subdomain_of?(base_domain)).to eq(false)
    end

    it "returns false on CNAME record with value that's not a subdomain" do
      expect(DDNSSD::DNSRecord.new("foo.example.com.", 42, :CNAME, "host1.freedom.com").subdomain_of?(base_domain)).to eq(false)
    end

    it "returns true on SRV record with that's a subdomain" do
      expect(DDNSSD::DNSRecord.new("bar._foo._tcp.example.com.", 42, :SRV, 0, 0, 8080, "bar1.example.com").subdomain_of?(base_domain)).to eq(true)
    end

    it "returns false on SRV record that's not a subdomain" do
      expect(DDNSSD::DNSRecord.new("bar._foo._tcp.freedom.com.", 42, :SRV, 0, 0, 8080, "bar1.freedom.com").subdomain_of?(base_domain)).to eq(false)
    end

    it "returns false on SRV record with value that's not a subdomain" do
      expect(DDNSSD::DNSRecord.new("bar._foo._tcp.example.com.", 42, :SRV, 0, 0, 8080, "bar1.freedom.com").subdomain_of?(base_domain)).to eq(false)
    end

    it "returns true on TXT record with that's a subdomain" do
      expect(DDNSSD::DNSRecord.new("bar._foo._tcp.example.com.", 42, :TXT, "nobugs").subdomain_of?(base_domain)).to eq(true)
    end

    it "returns false on TXT record that's not a subdomain" do
      expect(DDNSSD::DNSRecord.new("bar._foo._tcp.freedom.com.", 42, :TXT, "nobugs").subdomain_of?(base_domain)).to eq(false)
    end

    it "returns true on PTR record with that's a subdomain" do
      expect(DDNSSD::DNSRecord.new("_foo._tcp.example.com.", 42, :PTR, "bar._foo._tcp.example.com").subdomain_of?(base_domain)).to eq(true)
    end

    it "returns false on PTR record that's not a subdomain" do
      expect(DDNSSD::DNSRecord.new("_foo._tcp.freedom.com.", 42, :PTR, "bar._foo._tcp.freedom.com").subdomain_of?(base_domain)).to eq(false)
    end

    it "returns false on PTR record with value that's not a subdomain" do
      expect(DDNSSD::DNSRecord.new("_foo._tcp.example.com.", 42, :PTR, "bar._foo._tcp.freedom.com").subdomain_of?(base_domain)).to eq(false)
    end
  end
end

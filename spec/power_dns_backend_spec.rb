# frozen_string_literal: true

require_relative './spec_helper'

require 'ddnssd/backend/power_dns'
require 'ddnssd/power_dns/resource_record_store'

describe DDNSSD::Backend::PowerDNS do
  uses_logger

  after(:each) { pdns_db_clean }

  let(:base_env) { power_dns_test_config }
  let(:env) { base_env }
  let(:config) { DDNSSD::Config.new(env, logger: logger) }
  let(:backend) { DDNSSD::Backend::PowerDNS.new(config) }
  let(:rr_store) { DDNSSD::PowerDNS::ResourceRecordStore.new(backend, 'example.com', logger) }

  describe '.new' do
    %w(PG_DBNAME PG_USER PG_PASSWORD).each do |config_var|
      context "without #{config_var}" do
        let(:env) { base_env.reject { |k, v| k == "DDNSSD_POWER_DNS_#{config_var}" } }

        xit "raises an exception" do
          expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
        end
      end
    end

    context 'without PG_DNSNAME and PG_HOST' do
      let(:env) { base_env.reject { |k, v| k.end_with?('PG_DNSNAME') || k.end_with?('PG_HOST') } }

      xit 'raises an exception' do
        expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end
    end

    context "with PG_HOST but not PG_DNSNAME" do
      let(:env) do
        e = base_env
        e.delete('DDNSSD_POWER_DNS_PG_DNSNAME')
        e['DDNSSD_POWER_DNS_PG_HOST'] = 'localhost'
        e
      end

      xit 'is successful' do
        expect { backend }.to_not raise_error
      end
    end

    context "with PG_DNSNAME but not PG_HOST" do
      let(:env) do
        e = base_env
        e['DDNSSD_POWER_DNS_PG_DNSNAME'] = 'dns-sd._postgresql._tcp.sd.example.com'
        e.delete('DDNSSD_POWER_DNS_PG_HOST')
        e
      end

      xit 'is successful' do
        expect { backend }.to_not raise_error
      end
    end

    context "with both PG_DNSNAME and PG_HOST" do
      let(:env) do
        e = base_env
        e['DDNSSD_POWER_DNS_PG_DNSNAME'] = 'dns-sd._postgresql._tcp.sd.example.com'
        e['DDNSSD_POWER_DNS_PG_HOST'] = 'localhost'
        e
      end

      xit 'is successful' do
        expect { backend }.to_not raise_error
      end
    end
  end

  describe '#dns_records' do
    before { preload_db }

    xit "returns a list of DDNSSD::DNSRecord objects" do
      expect(backend.dns_records).to be_an(Array)
      expect(backend.dns_records.reject { |rr| DDNSSD::DNSRecord === rr }).to be_empty
      expect(backend.dns_records.all? { |rr| DDNSSD::DNSRecord === rr }).to be(true)
    end

    xit "returns A records" do
      expect(backend.dns_records.any? { |rr| rr.type == :A }).to be(true)
    end

    xit "A records are relative" do
      expect(backend.dns_records.find { |rr| rr.type == :A }.name).to eq('abcd1234.flingle')
    end

    xit "returns AAAA records" do
      expect(backend.dns_records.any? { |rr| rr.type == :AAAA }).to be(true)
    end

    xit "AAAA records are relative" do
      expect(backend.dns_records.find { |rr| rr.type == :AAAA }.name).to eq('flingle6')
    end

    xit "returns CNAME records" do
      expect(backend.dns_records.any? { |rr| rr.type == :CNAME }).to be(true)
    end

    xit "CNAME records are relative" do
      rr = backend.dns_records.find { |rr1| rr1.type == :CNAME }
      expect(rr.name).to eq('flinglec')
      expect(rr.data.name.to_s).to eq('host42')
    end

    xit "returns SRV records" do
      expect(backend.dns_records.any? { |rr| rr.type == :SRV }).to be(true)
    end

    xit "SRV records are relative" do
      records = backend.dns_records.select { |rr| rr.type == :SRV }
      records.each do |rr|
        expect(rr.name).to eq('faff._http._tcp')
        expect(rr.data.target.to_s.end_with?('.example.com')).to eq(false)
      end
    end

    xit "returns TXT records" do
      expect(backend.dns_records.any? { |rr| rr.type == :TXT }).to be(true)
    end

    xit "TXT records are relative" do
      expect(backend.dns_records.find { |rr| rr.type == :TXT }.name).to eq('faff._http._tcp')
    end

    xit "returns PTR records" do
      expect(backend.dns_records.any? { |rr| rr.type == :PTR }).to be(true)
    end

    xit "PTR records are relative" do
      rr = backend.dns_records.find { |rr1| rr1.type == :PTR }
      expect(rr.name).to eq('_http._tcp')
      expect(rr.data.name.to_s).to eq('faff._http._tcp')
    end

    xit "does not return SOA records" do
      expect(backend.dns_records.any? { |rr| rr.type == :SOA }).to be(false)
    end

    xit "does not return NS records" do
      expect(backend.dns_records.any? { |rr| rr.type == :NS }).to be(false)
    end

    xit "retries when there's an error" do
      allow(backend).to receive(:next_timeout).and_return(0.1)
      call_count = 0
      allow_any_instance_of(DDNSSD::PowerDNS::ResourceRecordStore).to receive(:all).and_wrap_original do |m, *args|
        call_count += 1
        if call_count == 1
          raise PG::ConnectionBad
        elsif call_count == 2
          raise PG::UndefinedTable
        elsif call_count == 3
          raise PG::UnableToSend
        else
          m.call(*args)
        end
      end

      expect(backend.dns_records).to be_an(Array)
      expect(backend.dns_records.all? { |rr| DDNSSD::DNSRecord === rr }).to be(true)
    end

    xit "skips records with values that aren't a subdomain" do
      allow(logger).to receive(:warn)
      rr_store.add(DDNSSD::DNSRecord.new('_http._tcp.example.com.', 42, :PTR, "faff._http._tcp.eggsamples.com"))
      expect(backend.dns_records.any? { |rr| rr.value&.end_with?('eggsamples.com') }).to be(false)
    end
  end

  describe '#publish_record' do
    context "with an NS record" do
      xit "raises an exception" do
        expect {
          backend.publish_record(
            DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")
          )
        }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with an A record" do
      let(:dns_record) { DDNSSD::DNSRecord.new("flingle", 42, :A, "192.0.2.42") }

      shared_examples "A upsert" do
        xit "upserts the A record" do
          backend.publish_record(dns_record)
          records = rr_store.lookup(name: "flingle.example.com")
          expect(records.size).to eq(1)
          new_record = records.first
          expect(new_record).to_not be_nil
          expect(new_record.ttl).to eq(42)
          expect(new_record.type).to eq('A')
          expect(new_record.content).to eq(dns_record.data.address.to_s)
        end
      end

      context 'no existing record' do
        it_behaves_like "A upsert"

        xit "can retry on some errors" do
          allow(backend).to receive(:next_timeout).and_return(0.1)
          call_count = 0
          allow_any_instance_of(DDNSSD::PowerDNS::ResourceRecordStore).to receive(:add).and_wrap_original do |m, *args|
            call_count += 1
            if call_count == 1
              raise PG::ConnectionBad
            elsif call_count == 2
              raise PG::UndefinedTable
            elsif call_count == 3
              raise PG::UnableToSend
            elsif call_count == 4
              raise PG::ObjectNotInPrerequisiteState
            else
              m.call(*args)
            end
          end

          backend.publish_record(dns_record)
          records = rr_store.lookup(name: "flingle.example.com")
          expect(records.size).to eq(1)
        end

        xit "logs unhandled exceptions and keeps running" do
          allow_any_instance_of(DDNSSD::PowerDNS::ResourceRecordStore).to receive(:add).and_raise('Splat!')
          expect(logger).to receive(:error).with(instance_of(String))
          expect { backend.publish_record(dns_record) }.to_not raise_error
        end
      end

      context 'existing record' do
        before { rr_store.add(DDNSSD::DNSRecord.new("flingle.example.com", 42, :A, "192.0.2.24")) }
        it_behaves_like "A upsert"

        context 'other records with same name' do
          before do
            rr_store.add(DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::42"))
            rr_store.add(DDNSSD::DNSRecord.new("flingle.example.com", 42, :TXT, "why is this record here"))
          end

          xit "it only affects the A record" do
            backend.publish_record(dns_record)
            records = rr_store.lookup(name: "flingle.example.com")
            expect(records.size).to eq(3)
            expect(records.map(&:type).map(&:to_sym)).to contain_exactly(:A, :AAAA, :TXT)
          end
        end
      end
    end

    context "with an AAAA record" do
      shared_examples "AAAA upsert" do
        xit "upserts the AAAA record" do
          dns_record = DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::24")
          backend.publish_record(dns_record)
          records = rr_store.lookup(name: "flingle.example.com")
          expect(records.size).to eq(1)
          new_record = records.first
          expect(new_record).to_not be_nil
          expect(new_record.ttl).to eq(42)
          expect(new_record.type).to eq('AAAA')
          expect(new_record.content).to eq(dns_record.data.address.to_s)
        end
      end

      context 'no existing record' do
        it_behaves_like "AAAA upsert"
      end

      context 'existing record' do
        before { rr_store.add(DDNSSD::DNSRecord.new("flingle.example.com", 42, :AAAA, "2001:db8::42")) }
        it_behaves_like "AAAA upsert"
      end
    end

    context "with a CNAME record" do
      shared_examples "CNAME upsert" do
        xit "upserts the CNAME record" do
          dns_record = DDNSSD::DNSRecord.new("db", 42, :CNAME, "pgsql.host27")
          backend.publish_record(dns_record)
          records = rr_store.lookup(name: "db.example.com")
          expect(records.size).to eq(1)
          new_record = records.first
          expect(new_record).to_not be_nil
          expect(new_record.ttl).to eq(42)
          expect(new_record.type).to eq('CNAME')
          expect(new_record.content).to eq("pgsql.host27.example.com")
        end
      end

      context 'no existing record' do
        it_behaves_like "CNAME upsert"
      end

      context 'existing record' do
        before { rr_store.add(DDNSSD::DNSRecord.new("db.example.com", 42, :CNAME, "pgsql.host26.example.com")) }
        it_behaves_like "CNAME upsert"
      end
    end

    context "with a TXT record" do
      shared_examples "TXT upsert" do
        xit "upserts the TXT record" do
          dns_record = DDNSSD::DNSRecord.new("faff._http._tcp", 42, :TXT, 'something "funny"', "this too")
          backend.publish_record(dns_record)
          records = rr_store.lookup(name: "faff._http._tcp.example.com")
          expect(records.size).to eq(1)
          new_record = records.first
          expect(new_record).to_not be_nil
          expect(new_record.ttl).to eq(42)
          expect(new_record.type).to eq('TXT')
          expect(new_record.content).to eq('"something \"funny\"" "this too"')
        end
      end

      context 'no existing record' do
        it_behaves_like "TXT upsert"
      end

      context 'existing record' do
        before { rr_store.add(DDNSSD::DNSRecord.new("faff._http._tcp.example.com", 42, :TXT, "old")) }
        it_behaves_like "TXT upsert"
      end
    end

    context "with a SRV record" do
      let(:dns_record) {
        DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22")
      }

      context "no existing recordset" do
        xit "creates a new SRV record" do
          backend.publish_record(dns_record)

          records = rr_store.lookup(name: "faff._http._tcp.example.com")
          expect(records.size).to eq(1)
          new_record = records.first
          expect(new_record).to_not be_nil
          expect(new_record.ttl).to eq(42)
          expect(new_record.type).to eq('SRV')
          expect(new_record.content).to eq("0 0 80 faff.host22.example.com")
        end
      end

      context "with existing records for the name/type" do
        before do
          [[0, 0, 80, 'faff.host1.example.com'],
            [0, 0, 8080, 'host3.example.com']].each do |values|
            rr_store.add(DDNSSD::DNSRecord.new('faff._http._tcp.example.com', 42, :SRV, *values))
          end
        end

        xit 'adds a SRV record to the existing recordset' do
          backend.publish_record(dns_record)

          records = rr_store.lookup(name: 'faff._http._tcp.example.com')
          expect(records.size).to eq(3)
          records.each do |rr|
            expect(rr.ttl).to eq(42)
            expect(rr.type).to eq('SRV')
          end
          expect(records.map(&:content)).to contain_exactly(
            '0 0 80 faff.host1.example.com',
            '0 0 8080 host3.example.com',
            '0 0 80 faff.host22.example.com'
          )
        end

        xit 'does nothing when the record already exists' do
          allow(logger).to receive(:warn).with(instance_of(String))

          existing = DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host3")

          backend.publish_record(existing)

          records = rr_store.lookup(name: 'faff._http._tcp.example.com')
          expect(records.size).to eq(2)
          expect(records.map(&:content)).to contain_exactly(
            '0 0 80 faff.host1.example.com',
            '0 0 8080 host3.example.com'
          )
        end
      end
    end

    context 'with a PTR record' do

      let(:dns_record) do
        DDNSSD::DNSRecord.new(
          '_http._tcp', 42, :PTR, 'faff._http._tcp'
        )
      end

      context 'with no existing recordset' do
        xit 'creates a new PTR record' do
          backend.publish_record(dns_record)

          records = rr_store.lookup(type: :PTR, name: '_http._tcp.example.com')
          expect(records.size).to eq(1)
          rr = records.first
          expect(rr.ttl).to eq(42)
          expect(rr.content).to eq('faff._http._tcp.example.com')
        end
      end

      context 'with existing records for the name/type' do
        before do
          ['xyzzy._http._tcp', 'argle._http._tcp'].each do |value|
            rr_store.add(DDNSSD::DNSRecord.new('_http._tcp.example.com', 42, :PTR, "#{value}.example.com"))
          end
        end

        xit 'creates a new PTR record' do
          backend.publish_record(dns_record)

          records = rr_store.lookup(type: :PTR, name: '_http._tcp.example.com')
          expect(records.size).to eq(3)
          records.each do |rr|
            expect(rr.ttl).to eq(42)
            expect(rr.type).to eq('PTR')
          end
          expect(records.map(&:content)).to contain_exactly(
            'xyzzy._http._tcp.example.com',
            'argle._http._tcp.example.com',
            'faff._http._tcp.example.com'
          )
        end

        xit 'does nothing when the record already exists' do
          rr_store.add(dns_record)

          allow(logger).to receive(:warn).with(instance_of(String))

          backend.publish_record(dns_record)

          records = rr_store.lookup(type: :PTR, name: '_http._tcp.example.com')
          expect(records.size).to eq(3)
          expect(records.map(&:content)).to contain_exactly(
            'xyzzy._http._tcp.example.com',
            'argle._http._tcp.example.com',
            'faff._http._tcp.example.com'
          )
        end
      end
    end
  end

  describe '#suppress_record' do
    context 'with a NS record' do
      xit 'raises an error' do
        expect {
          backend.suppress_record(DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com"))
        }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context 'with an A record' do
      let(:dns_record) {
        DDNSSD::DNSRecord.new('abcd1234.flingle', 42, :A, '192.0.2.42')
      }

      context 'with no other records in the set' do
        before do
          rr_store.add(dns_record)
        end

        xit 'deletes the record set' do
          backend.suppress_record(dns_record)
          records = rr_store.lookup(type: :A, name: 'abcd1234.flingle.example.com')
          expect(records.size).to eq(0)
        end

        xit "logs exceptions and keeps running" do
          allow_any_instance_of(DDNSSD::PowerDNS::ResourceRecordStore).to receive(:remove).and_raise('Zonk!')
          expect(logger).to receive(:error).with(instance_of(String))
          expect { backend.suppress_record(dns_record) }.to_not raise_error
        end
      end

      context 'with other records in the set' do
        before(:each) do
          ['192.0.2.1', '192.0.2.42', '192.0.2.180'].each do |content|
            rr_store.add(DDNSSD::DNSRecord.new('abcd1234.flingle.example.com', 42, :A, content))
          end
        end

        xit 'removes the record' do
          backend.suppress_record(dns_record)
          records = rr_store.lookup(type: :A, name: 'abcd1234.flingle.example.com')
          expect(records.size).to eq(2)
          expect(records.map(&:content)).to contain_exactly('192.0.2.1', '192.0.2.180')
        end
      end

      context 'record already gone' do
        before(:each) do
          ['192.0.2.1', '192.0.2.180'].each do |content|
            rr_store.add(DDNSSD::DNSRecord.new('abcd1234.flingle.example.com', 42, :A, content))
          end
        end

        xit 'changes nothing' do
          backend.suppress_record(dns_record)
          records = rr_store.lookup(type: :A, name: 'abcd1234.flingle.example.com')
          expect(records.size).to eq(2)
          expect(records.map(&:content)).to contain_exactly('192.0.2.1', '192.0.2.180')
        end
      end
    end

    context 'with an AAAA record' do
      let(:dns_record) {
        DDNSSD::DNSRecord.new('flingle', 42, :AAAA, '2001:db8::42')
      }

      context 'with no other records in the set' do
        before do
          rr_store.add(dns_record)
        end

        xit 'deletes the record set' do
          backend.suppress_record(dns_record)
          records = rr_store.lookup(type: :AAAA, name: 'flingle.example.com')
          expect(records.size).to eq(0)
        end
      end

      context 'with other records in the set' do
        before(:each) do
          ['2001:db8::1', '2001:db8::42', '2001:db8::180'].each do |content|
            rr_store.add(DDNSSD::DNSRecord.new('flingle.example.com', 42, :AAAA, content))
          end
        end

        xit 'removes the record' do
          backend.suppress_record(dns_record)
          records = rr_store.lookup(type: :AAAA, name: 'flingle.example.com')
          expect(records.size).to eq(2)
          expect(records.map(&:content)).to contain_exactly('2001:DB8::1', '2001:DB8::180')
        end
      end

      context 'record already gone' do
        before(:each) do
          ['2001:db8::1', '2001:db8::180'].each do |content|
            rr_store.add(DDNSSD::DNSRecord.new('flingle.example.com', 42, :AAAA, content))
          end
        end

        xit 'changes nothing' do
          backend.suppress_record(dns_record)
          records = rr_store.lookup(type: :AAAA, name: 'flingle.example.com')
          expect(records.size).to eq(2)
          expect(records.map(&:content)).to contain_exactly('2001:DB8::1', '2001:DB8::180')
        end
      end
    end

    context 'with a CNAME record' do
      let(:dns_record) {
        DDNSSD::DNSRecord.new('flingle', 42, :CNAME, 'host42')
      }

      context 'with no other records in the set' do
        before do
          rr_store.add(dns_record)
        end

        xit 'deletes the record set' do
          backend.suppress_record(dns_record)
          records = rr_store.lookup(type: :CNAME, name: 'flingle.example.com')
          expect(records.size).to eq(0)
        end
      end

      context 'with other records in the set' do
        before(:each) do
          ['host1.example.com', 'host42.example.com', 'host180.example.com'].each do |value|
            rr_store.add(DDNSSD::DNSRecord.new('flingle.example.com', 42, :CNAME, value))
          end
        end

        xit 'removes the record' do
          backend.suppress_record(dns_record)
          records = rr_store.lookup(type: :CNAME, name: 'flingle.example.com')
          expect(records.size).to eq(2)
          expect(records.map(&:content)).to contain_exactly('host1.example.com', 'host180.example.com')
        end
      end

      context 'record already gone' do
        before(:each) do
          ['host1.example.com', 'host180.example.com'].each do |content|
            rr_store.add(DDNSSD::DNSRecord.new('flingle.example.com', 42, :CNAME, content))
          end
        end

        xit 'changes nothing' do
          backend.suppress_record(dns_record)
          records = rr_store.lookup(type: :CNAME, name: 'flingle.example.com')
          expect(records.size).to eq(2)
          expect(records.map(&:content)).to contain_exactly('host1.example.com', 'host180.example.com')
        end
      end
    end

    context 'with a SRV record' do
      context 'with other SRV records present' do
        before do
          [[0, 0, 80, 'host1.example.com'],
            [0, 0, 8080, 'host2.example.com']].each do |values|
            rr_store.add(DDNSSD::DNSRecord.new('faff._http._tcp.example.com', 42, :SRV, *values))
          end
        end

        xit 'deletes the SRV record' do
          # missing TXT record can log a warning
          allow(logger).to receive(:warn).with(instance_of(String))

          backend.suppress_record(
            DDNSSD::DNSRecord.new('faff._http._tcp', 42, :SRV, 0, 0, 8080, 'host2')
          )

          records = rr_store.lookup(type: :SRV, name: 'faff._http._tcp.example.com')
          expect(records.size).to eq(1)
          expect(records.map(&:content)).to contain_exactly('0 0 80 host1.example.com')
        end

        xit 'does nothing if SRV record does not exist' do
          allow(logger).to receive(:warn).with(instance_of(String))

          backend.suppress_record(
            DDNSSD::DNSRecord.new('faff._http._tcp', 42, :SRV, 0, 0, 80, 'host3')
          )

          records = rr_store.lookup(type: :SRV, name: 'faff._http._tcp.example.com')
          expect(records.size).to eq(2)
          expect(records.map(&:content)).to contain_exactly('0 0 80 host1.example.com', '0 0 8080 host2.example.com')
        end

        context 'and matching TXT and PTR records' do
          before do
            rr_store.add(DDNSSD::DNSRecord.new('faff._http._tcp.example.com', 42, :TXT, 'fastplease'))
            rr_store.add(DDNSSD::DNSRecord.new('_http._tcp.example.com', 42, :PTR, 'faff._http._tcp.example.com'))
          end

          xit 'should only delete the SRV record' do
            backend.suppress_record(
              DDNSSD::DNSRecord.new('faff._http._tcp', 42, :SRV, 0, 0, 8080, 'host2')
            )

            records = rr_store.lookup(type: :SRV, name: 'faff._http._tcp.example.com')
            expect(records.size).to eq(1)
            expect(records.map(&:content)).to contain_exactly('0 0 80 host1.example.com')

            expect(rr_store.lookup(type: :TXT, name: 'faff._http._tcp.example.com').size).to eq(1)

            ptr_records = rr_store.lookup(type: :PTR, name: '_http._tcp.example.com')
            expect(ptr_records.size).to eq(1)
            expect(ptr_records.first.content).to eq('faff._http._tcp.example.com')
          end
        end
      end

      context 'with no other SRV records present' do
        let(:srv_record) {
          DDNSSD::DNSRecord.new('faff._http._tcp', 42, :SRV, 0, 0, 80, 'host1')
        }

        before do
          rr_store.add(DDNSSD::DNSRecord.new('faff._http._tcp.example.com', 42, :SRV, 0, 0, 80, 'host1.example.com'))
          rr_store.add(DDNSSD::DNSRecord.new('faff._http._tcp.example.com', 42, :TXT, 'wrecka stow'))
          rr_store.add(DDNSSD::DNSRecord.new("_http._tcp.example.com", 42, :PTR, "faff._http._tcp.example.com"))
        end

        context 'with no other PTR records' do
          xit 'deletes the SRV, TXT, and PTR record sets' do
            backend.suppress_record(srv_record)

            expect(rr_store.lookup(type: :SRV, name: 'faff._http._tcp.example.com').size).to eq(0)
            expect(rr_store.lookup(type: :TXT, name: 'faff._http._tcp.example.com').size).to eq(0)
            expect(rr_store.lookup(type: :PTR, name: '_http._tcp.example.com').size).to eq(0)
          end

          xit 'can rollback on exceptions' do
            allow_any_instance_of(DDNSSD::PowerDNS::ResourceRecordStore).to receive(:remove_with).and_wrap_original { |m, *args| m.call(*args) }
            allow_any_instance_of(DDNSSD::PowerDNS::ResourceRecordStore).to receive(:remove_with).with(type: :TXT, name: "#{srv_record.name}.example.com").and_raise('Oopsie')

            expect(logger).to receive(:error).with(instance_of(String))
            expect { backend.suppress_record(srv_record) }.to_not raise_error

            expect(rr_store.lookup(type: :SRV, name: 'faff._http._tcp.example.com').size).to eq(1)
            expect(rr_store.lookup(type: :TXT, name: 'faff._http._tcp.example.com').size).to eq(1)
            expect(rr_store.lookup(type: :PTR, name: '_http._tcp.example.com').size).to eq(1)
          end
        end

        context 'with other PTR records' do
          before do
            rr_store.add(DDNSSD::DNSRecord.new('_http._tcp.example.com', 42, :PTR, 'blargh._http._tcp.example.com'))
            rr_store.add(DDNSSD::DNSRecord.new('blargh._http._tcp.example.com', 42, :SRV, 0, 0, 80, 'host7.example.com'))
            rr_store.add(DDNSSD::DNSRecord.new('blargh._http._tcp.example.com', 42, :TXT, 'fastplease'))
          end

          xit "deletes the SRV, TXT and PTR records" do
            backend.suppress_record(srv_record)
            expect(rr_store.lookup(type: :SRV, name: 'faff._http._tcp.example.com').size).to eq(0)
            expect(rr_store.lookup(type: :TXT, name: 'faff._http._tcp.example.com').size).to eq(0)
            ptr_records = rr_store.lookup(type: :PTR, name: '_http._tcp.example.com')
            expect(ptr_records.size).to eq(1)
            expect(ptr_records.first.content).to eq('blargh._http._tcp.example.com')
            expect(rr_store.lookup(type: :SRV, name: 'blargh._http._tcp.example.com').size).to eq(1)
            expect(rr_store.lookup(type: :TXT, name: 'blargh._http._tcp.example.com').size).to eq(1)
          end

          xit "can retry on some errors" do
            allow(backend).to receive(:next_timeout).and_return(0.1)
            call_count = 0

            # Fail mid-transaction for extra fun
            allow_any_instance_of(DDNSSD::PowerDNS::ResourceRecordStore).to receive(:remove_with).and_wrap_original do |m, *args|
              call_count += 1
              if call_count == 1
                raise PG::ConnectionBad
              elsif call_count == 2
                raise PG::UndefinedTable
              elsif call_count == 3
                raise PG::UnableToSend
              else
                m.call(*args)
              end
            end

            backend.suppress_record(srv_record)
            expect(rr_store.lookup(type: :SRV, name: 'faff._http._tcp.example.com').size).to eq(0)
            expect(rr_store.lookup(type: :TXT, name: 'faff._http._tcp.example.com').size).to eq(0)
            ptr_records = rr_store.lookup(type: :PTR, name: '_http._tcp.example.com')
            expect(ptr_records.size).to eq(1)
            expect(ptr_records.first.content).to eq('blargh._http._tcp.example.com')
            expect(rr_store.lookup(type: :SRV, name: 'blargh._http._tcp.example.com').size).to eq(1)
            expect(rr_store.lookup(type: :TXT, name: 'blargh._http._tcp.example.com').size).to eq(1)
          end
        end
      end
    end

    context 'with a TXT record' do
      xit "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("x.example.com", 60, :TXT, "")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context 'with a PTR record' do
      xit "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("x.example.com", 60, :PTR, "faff.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end
  end

  describe 'rest' do
    xit "doesn't break later calls to publish_record" do
      backend.publish_record(DDNSSD::DNSRecord.new("flingle", 42, :A, "192.0.2.42"))
      backend.rest
      backend.publish_record(DDNSSD::DNSRecord.new("kaboom", 42, :A, "192.0.2.43"))
      records = rr_store.lookup(name: "kaboom.example.com")
      expect(records.size).to eq(1)
    end
  end
end

# frozen_string_literal: true
require_relative './spec_helper'

require 'ddnssd/backend/route53'

describe DDNSSD::Backend::Route53 do
  uses_logger

  let(:base_env) do
    {
      "DDNSSD_HOSTNAME"        => "speccy",
      "DDNSSD_BACKEND"         => "route53",
      "DDNSSD_BASE_DOMAIN"     => "example.com",
      "DDNSSD_ROUTE53_ZONE_ID" => "Z3M3LMPEXAMPLE"
    }
  end
  let(:env) { base_env }
  let(:config) { DDNSSD::Config.new(env, logger: logger) }

  let(:backend) { DDNSSD::Backend::Route53.new(config) }

  let(:r53) { Aws::Route53::Client.new(region: 'nope') }
  let(:route53_stubs) { {} }

  before(:each) do
    Aws.config[:route53] = { stub_responses: route53_stubs }
    allow(Aws::Route53::Client).to receive(:new).and_return(r53)
  end

  describe ".new" do
    context "without a ZONE_ID specified" do
      let(:env) { base_env.reject { |k, v| k == "DDNSSD_ROUTE53_ZONE_ID" } }

      it "raises an exception" do
        expect { backend }.to raise_error(DDNSSD::Config::InvalidEnvironmentError)
      end
    end
  end

  describe "#dns_records" do
    context "one page of records" do
      let(:route53_stubs) do
        {
          list_resource_record_sets: route53_response_fixture("one_page_of_records")
        }
      end

      it "asks for the records of the correct zone ID" do
        expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil).and_call_original

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
    end

    context "with a multi-page list of record sets" do
      let(:route53_stubs) do
        {
          list_resource_record_sets: ->(context) do
            if context.params[:start_record_name].nil? && context.params[:start_record_type].nil?
              route53_response_fixture("page_of_records_1_of_2")
            elsif context.params[:start_record_name] == "faff" && context.params[:start_record_type] == "XYZZY"
              route53_response_fixture("page_of_records_2_of_2")
            else
              raise ArgumentError,
                "Unknown paginated request"
            end
          end
        }
      end

      it "asks for the records of each page in turn" do
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil)
          .and_call_original.ordered
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff", start_record_type: "XYZZY")
          .and_call_original.ordered

        backend.dns_records
      end

      it "returns a list of DDNSSD::DNSRecord objects" do
        expect(backend.dns_records).to be_an(Array)
        expect(backend.dns_records.all? { |rr| DDNSSD::DNSRecord === rr }).to be(true)
      end

      it "includes a record from the first page" do
        expect(backend.dns_records).to have_A_record("foo", "192.0.2.42")
      end

      it "includes a record from the second page" do
        expect(backend.dns_records).to have_A_record("baz", "192.0.2.242")
      end
    end

    context "on receiving Throttling error" do
      let(:route53_stubs) do
        req_count = 0
        {
          list_resource_record_sets: ->(context) do
            req_count += 1
            if [1, 2, 3, 5].include?(req_count)
              'Throttling'
            elsif context.params[:start_record_name].nil? && context.params[:start_record_type].nil?
              route53_response_fixture("page_of_records_1_of_2")
            elsif context.params[:start_record_name] == "faff" && context.params[:start_record_type] == "XYZZY"
              route53_response_fixture("page_of_records_2_of_2")
            else
              raise ArgumentError,
                "Unknown paginated request"
            end
          end
        }
      end

      it "asks for the records of each page in turn, retrying throttles after a delay" do
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil)
          .and_call_original
        expect(Kernel).to receive(:sleep).with(a_value_between(0.5, 1))
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil)
          .and_call_original
        expect(Kernel).to receive(:sleep).with(a_value_between(0.55, 2.1))
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil)
          .and_call_original
        expect(Kernel).to receive(:sleep).with(a_value_between(0.605, 3.31))
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil)
          .and_call_original
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff", start_record_type: "XYZZY")
          .and_call_original
        expect(Kernel).to receive(:sleep).with(a_value_between(0.5, 1))
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff", start_record_type: "XYZZY")
          .and_call_original

        backend.dns_records
      end
    end

    context "on receiving PriorRequestNotComplete error" do
      let(:route53_stubs) do
        req_count = 0
        {
          list_resource_record_sets: ->(context) do
            req_count += 1
            if [1, 3, 4, 5].include?(req_count)
              'PriorRequestNotComplete'
            elsif context.params[:start_record_name].nil? && context.params[:start_record_type].nil?
              route53_response_fixture("page_of_records_1_of_2")
            elsif context.params[:start_record_name] == "faff" && context.params[:start_record_type] == "XYZZY"
              route53_response_fixture("page_of_records_2_of_2")
            else
              raise ArgumentError,
                "Unknown paginated request"
            end
          end
        }
      end

      it "asks for the records of each page in turn, retrying throttles after a delay" do
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil)
          .and_call_original
        expect(Kernel).to receive(:sleep).with(a_value_between(0.5, 1))
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil)
          .and_call_original
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff", start_record_type: "XYZZY")
          .and_call_original
        expect(Kernel).to receive(:sleep).with(a_value_between(0.5, 1))
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff", start_record_type: "XYZZY")
          .and_call_original
        expect(Kernel).to receive(:sleep).with(a_value_between(0.55, 2.1))
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff", start_record_type: "XYZZY")
          .and_call_original
        expect(Kernel).to receive(:sleep).with(a_value_between(0.605, 3.31))
        expect(r53).to receive(:list_resource_record_sets)
          .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff", start_record_type: "XYZZY")
          .and_call_original

        backend.dns_records
      end

      context "constantly" do
        let(:route53_stubs) do
          {
            list_resource_record_sets: 'PriorRequestNotComplete'
          }
        end

        it "retries up to the default limit, then gives up and logs an error" do
          with_overridden_constant(DDNSSD::Backend::Route53::Retryable, :DEFAULT_RETRY_LIMIT, 17) do
            16.times do
              expect(r53).to receive(:list_resource_record_sets)
                .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil)
                .and_call_original.ordered
              expect(Kernel).to receive(:sleep).ordered
            end
            expect(r53).to receive(:list_resource_record_sets)
              .with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: nil, start_record_type: nil)
              .and_call_original.ordered

            expect(logger).to receive(:error)
            expect(r53).to_not receive(:list_resource_record_sets)

            backend.dns_records
          end
        end
      end
    end

    context "on other errors" do
      let(:route53_stubs) do
        {
          list_resource_record_sets: 'FunkyError'
        }
      end

      before(:each) { allow(logger).to receive(:error) }

      it "logs the error" do
        expect(logger).to receive(:error)

        backend.dns_records
      end

      it "returns an empty list" do
        expect(backend.dns_records).to be_empty
      end
    end

    context "receiving records with value having wrong subdomain" do
      let(:route53_stubs) do
        {
          list_resource_record_sets: route53_response_fixture("wrong_subdomain")
        }
      end

      it "tolerates it" do
        allow(logger).to receive(:warn)
        expect {
          records = backend.dns_records
          expect(backend.dns_records).to be_an(Array)
          expect(backend.dns_records.reject { |rr| DDNSSD::DNSRecord === rr }).to be_empty
          expect(backend.dns_records.all? { |rr| DDNSSD::DNSRecord === rr }).to be(true)
        }.to_not raise_error
      end
    end
  end

  describe "#publish_record" do
    let(:route53_stubs) do
      {
        change_resource_record_sets: {
          change_info: {
            id: "xyzzy",
            status: "PENDING",
            submitted_at: Time.now
          }
        }
      }
    end

    context "with an NS record" do
      it "raises an exception" do
        expect { backend.publish_record(DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with an A record" do
      it "upserts the A record" do
        expect(r53).to receive(:change_resource_record_sets)
          .with(change_batch: {
                  changes: [
                    {
                      action: "UPSERT",
                      resource_record_set: {
                        name: "flingle.example.com",
                        type: "A",
                        ttl: 42,
                        resource_records: [
                          { value: "192.0.2.42" }
                        ]
                      }
                    }
                  ]
                },
                hosted_zone_id: "Z3M3LMPEXAMPLE"
               )
          .and_call_original
        expect(r53).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("flingle", 42, :A, "192.0.2.42"))
      end

      context "on Throttling error" do
        let(:route53_stubs) do
          req_count = 0
          {
            change_resource_record_sets: ->(context) do
              req_count += 1
              if req_count < 4
                'Throttling'
              else
                {
                  change_info: {
                    id: "xyzzy",
                    status: "PENDING",
                    submitted_at: Time.now
                  }
                }
              end
            end
          }
        end

        it "backs off and retries" do
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.5, 1)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.55, 2.1)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.605, 3.31)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to_not receive(:sleep)

          backend.publish_record(DDNSSD::DNSRecord.new("flingle", 42, :A, "192.0.2.42"))
        end
      end

      context "on PriorRequestNotComplete error" do
        let(:route53_stubs) do
          req_count = 0
          {
            change_resource_record_sets: ->(context) do
              req_count += 1
              if req_count < 4
                'PriorRequestNotComplete'
              else
                {
                  change_info: {
                    id: "xyzzy",
                    status: "PENDING",
                    submitted_at: Time.now
                  }
                }
              end
            end
          }
        end

        it "backs off and retries" do
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.5, 1)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.55, 2.1)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.605, 3.31)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to_not receive(:sleep)

          backend.publish_record(DDNSSD::DNSRecord.new("flingle", 42, :A, "192.0.2.42"))
        end
      end
    end

    context "with a AAAA record" do
      it "upserts the AAAA record" do
        expect(r53).to receive(:change_resource_record_sets)
          .with(change_batch: {
                  changes: [
                    {
                      action: "UPSERT",
                      resource_record_set: {
                        name: "flingle.example.com",
                        type: "AAAA",
                        ttl: 42,
                        resource_records: [
                          { value: "2001:DB8::42" }
                        ]
                      }
                    }
                  ]
                },
                hosted_zone_id: "Z3M3LMPEXAMPLE"
               )
          .and_call_original
        expect(r53).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"))
      end
    end

    context "with a CNAME record" do
      it "upserts the CNAME record" do
        expect(r53).to receive(:change_resource_record_sets)
          .with(change_batch: {
                  changes: [
                    {
                      action: "UPSERT",
                      resource_record_set: {
                        name: "db.example.com",
                        type: "CNAME",
                        ttl: 42,
                        resource_records: [
                          { value: "pgsql.host27.example.com" }
                        ]
                      }
                    }
                  ]
                },
                hosted_zone_id: "Z3M3LMPEXAMPLE"
               )
          .and_call_original
        expect(r53).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("db", 42, :CNAME, "pgsql.host27"))
      end
    end

    context "with a TXT record" do
      it "upserts the TXT record" do
        expect(r53).to receive(:change_resource_record_sets)
          .with(change_batch: {
                  changes: [
                    {
                      action: "UPSERT",
                      resource_record_set: {
                        name: "faff._http._tcp.example.com",
                        type: "TXT",
                        ttl: 42,
                        resource_records: [
                          { value: '"something \"funny\"" "this too"' }
                        ]
                      }
                    }
                  ]
                },
                hosted_zone_id: "Z3M3LMPEXAMPLE"
               )
          .and_call_original
        expect(r53).to_not receive(:list_resource_record_sets)

        backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :TXT, 'something "funny"', "this too"))
      end
    end

    context "with a SRV record" do
      context "no existing recordset" do
        it "creates a new SRV record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host22.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
        end
      end

      context "with existing records for the name/type" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host1"),
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host3")
          )
        end

        it "adds a SRV record to the existing recordset" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host1.example.com" },
                            { value: "0 0 8080 host3.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host1.example.com" },
                            { value: "0 0 8080 host3.example.com" },
                            { value: "0 0 80 faff.host22.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
        end
      end

      context "with the record already existent" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host1"),
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host3"),
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22")
          )
        end

        it "makes sure we're up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host1.example.com" },
                            { value: "0 0 8080 host3.example.com" },
                            { value: "0 0 80 faff.host22.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 80 faff.host1.example.com" },
                            { value: "0 0 8080 host3.example.com" },
                            { value: "0 0 80 faff.host22.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
        end
      end

      context "on InvalidChangeBatch error" do
        let(:route53_stubs) do
          already_called = false
          {
            list_resource_record_sets: rr_list,
            change_resource_record_sets: ->(context) do
              unless already_called
                already_called = true
                'InvalidChangeBatch'
              else
                {
                  change_info: {
                    id: "xyzzy",
                    status: "PENDING",
                    submitted_at: Time.now
                  }
                }
              end
            end
          }
        end

        context "with records appearing" do
          let(:rr_list) { route53_response_fixture("faff_srv") }

          it "refreshes the zone data and retries the request with the new values" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 80 faff.host22.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(backend).to receive(:sleep).with(a_value_between(0, 2)).ordered
            expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff._http._tcp.example.com", start_record_type: "SRV", max_items: 1).and_call_original.ordered
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 80 faff.host1.example.com" },
                              { value: "0 0 8080 host3.example.com" }
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 80 faff.host1.example.com" },
                              { value: "0 0 8080 host3.example.com" },
                              { value: "0 0 80 faff.host22.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   )
              .and_call_original
            expect(r53).to_not receive(:list_resource_record_sets).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
          end
        end

        context "with records disappearing" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host1"),
              DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host3")
            )
          end

          let(:rr_list) { route53_response_fixture("some_other_record") }

          it "refreshes the zone data and retries the request with the new values" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 80 faff.host1.example.com" },
                              { value: "0 0 8080 host3.example.com" }
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 80 faff.host1.example.com" },
                              { value: "0 0 8080 host3.example.com" },
                              { value: "0 0 80 faff.host22.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(backend).to receive(:sleep).with(a_value_between(0, 2))
            expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff._http._tcp.example.com", start_record_type: "SRV", max_items: 1).and_call_original.ordered
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 80 faff.host22.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(r53).to_not receive(:list_resource_record_sets).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
          end
        end

        context "and never resolving" do
          let(:route53_stubs) do
            {
              list_resource_record_sets: route53_response_fixture("faff_srv"),
              change_resource_record_sets: 'InvalidChangeBatch'
            }
          end

          it "retries for a while then gives up" do
            with_overridden_constant(DDNSSD::Backend::Route53::Retryable, :DEFAULT_RETRY_LIMIT, 42) do
              expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered

              41.times do
                expect(backend).to receive(:sleep).with(a_value_between(0, 2))
                expect(r53).to receive(:list_resource_record_sets).and_call_original.ordered
                expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
              end

              expect(logger).to receive(:error).ordered

              expect(r53).to_not receive(:list_resource_record_sets)
              expect(r53).to_not receive(:change_resource_record_sets)

              backend.publish_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22"))
            end
          end
        end
      end
    end

    context "with a PTR record" do
      context "no existing recordset" do
        it "creates a new PTR record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "faff._http._tcp.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
        end
      end

      context "with existing records for the name/type" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "xyzzy._http._tcp"),
            DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "argle._http._tcp")
          )
        end

        it "adds a PTR record to the existing recordset" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "xyzzy._http._tcp.example.com" },
                            { value: "argle._http._tcp.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "xyzzy._http._tcp.example.com" },
                            { value: "argle._http._tcp.example.com" },
                            { value: "faff._http._tcp.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
        end
      end

      context "including the one we want to add" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp")
          )
        end

        it "runs a no-change change to ensure everything's up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "faff._http._tcp.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "_http._tcp.example.com",
                          type: "PTR",
                          ttl: 42,
                          resource_records: [
                            { value: "faff._http._tcp.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
        end
      end

      context "on InvalidChangeBatch error" do
        let(:route53_stubs) do
          already_called = false
          {
            list_resource_record_sets: rr_list,
            change_resource_record_sets: ->(context) do
              unless already_called
                already_called = true
                'InvalidChangeBatch'
              else
                {
                  change_info: {
                    id: "xyzzy",
                    status: "PENDING",
                    submitted_at: Time.now
                  }
                }
              end
            end
          }
        end

        context "with records appearing" do
          let(:rr_list) { route53_response_fixture("http_ptr") }

          it "refreshes the zone data and retries the request with the new values" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(backend).to receive(:sleep).with(a_value_between(0, 2))
            expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "_http._tcp.example.com", start_record_type: "PTR", max_items: 1).and_call_original.ordered
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "xyzzy._http._tcp.example.com" },
                              { value: "argle._http._tcp.example.com" }
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "xyzzy._http._tcp.example.com" },
                              { value: "argle._http._tcp.example.com" },
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   )
              .and_call_original
            expect(r53).to_not receive(:list_resource_record_sets).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
          end
        end

        context "with records disappearing" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "xyzzy._http._tcp"),
              DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "argle._http._tcp")
            )
          end

          let(:rr_list) { route53_response_fixture("some_other_record") }

          it "refreshes the zone data and retries the request with the new values" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "xyzzy._http._tcp.example.com" },
                              { value: "argle._http._tcp.example.com" }
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "xyzzy._http._tcp.example.com" },
                              { value: "argle._http._tcp.example.com" },
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(backend).to receive(:sleep).with(a_value_between(0, 2))
            expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "_http._tcp.example.com", start_record_type: "PTR", max_items: 1).and_call_original.ordered
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(r53).to_not receive(:list_resource_record_sets).ordered

            backend.publish_record(DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp"))
          end
        end
      end
    end
  end

  describe "#suppress_record" do
    context "with an A record" do
      context "with no other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42")
          )
        end

        it "deletes the record set" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.42" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
        end
      end

      context "with other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.1"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.180")
          )
        end

        it "modifies the record set to remove our record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.1" },
                            { value: "192.0.2.42" },
                            { value: "192.0.2.180" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.1" },
                            { value: "192.0.2.180" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
        end
      end

      context "with our record already gone" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.1"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.180")
          )
        end

        it "makes a no-op request to make sure everything is up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.1" },
                            { value: "192.0.2.180" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.1" },
                            { value: "192.0.2.180" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
        end
      end

      context "when faced with an InvalidChangeBatch error" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42")
          )
        end

        let(:route53_stubs) do
          already_called = false
          {
            list_resource_record_sets: route53_response_fixture("abcd1234_flingle_a"),
            change_resource_record_sets: ->(context) do
              unless already_called
                already_called = true
                'InvalidChangeBatch'
              else
                {
                  change_info: {
                    id: "xyzzy",
                    status: "PENDING",
                    submitted_at: Time.now
                  }
                }
              end
            end
          }
        end

        it "refreshes the cache and tries the change again" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.42" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 ).and_call_original.ordered
          expect(backend).to receive(:sleep).with(a_value_between(0, 2))
          expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "abcd1234.flingle.example.com", start_record_type: "A", max_items: 1).and_call_original.ordered
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "abcd1234.flingle.example.com",
                          type: "A",
                          ttl: 42,
                          resource_records: [
                            { value: "192.0.2.42" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets).ordered

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
        end

        context "that never resolves" do
          let(:route53_stubs) do
            {
              list_resource_record_sets: route53_response_fixture("abcd1234_flingle_a"),
              change_resource_record_sets: 'InvalidChangeBatch'
            }
          end

          it "retries for a while then gives up" do
            with_overridden_constant(DDNSSD::Backend::Route53::Retryable, :DEFAULT_RETRY_LIMIT, 42) do
              expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered

              41.times do
                expect(backend).to receive(:sleep).with(a_value_between(0, 2))
                expect(r53).to receive(:list_resource_record_sets).and_call_original.ordered
                expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
              end

              expect(logger).to receive(:error).ordered

              expect(r53).to_not receive(:list_resource_record_sets)
              expect(r53).to_not receive(:change_resource_record_sets)

              backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
            end
          end
        end
      end

      context "on Throttling error" do
        let(:route53_stubs) do
          req_count = 0
          {
            change_resource_record_sets: ->(context) do
              req_count += 1
              if req_count < 4
                'Throttling'
              else
                {
                  change_info: {
                    id: "xyzzy",
                    status: "PENDING",
                    submitted_at: Time.now
                  }
                }
              end
            end
          }
        end

        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.1"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.180")
          )
        end

        it "backs off and retries" do
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.5, 1)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.55, 2.1)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.605, 3.31)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to_not receive(:sleep)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
        end
      end

      context "on PriorRequestNotComplete error" do
        let(:route53_stubs) do
          req_count = 0
          {
            change_resource_record_sets: ->(context) do
              req_count += 1
              if req_count < 4
                'PriorRequestNotComplete'
              else
                {
                  change_info: {
                    id: "xyzzy",
                    status: "PENDING",
                    submitted_at: Time.now
                  }
                }
              end
            end
          }
        end

        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.1"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"),
            DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.180")
          )
        end

        it "backs off and retries" do
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.5, 1)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.55, 2.1)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to receive(:sleep).with(a_value_between(0.605, 3.31)).ordered
          expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
          expect(Kernel).to_not receive(:sleep)

          backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.flingle", 42, :A, "192.0.2.42"))
        end
      end
    end

    context "with a AAAA record" do
      context "with no other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42")
          )
        end

        it "deletes the record set" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::42" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"))
        end
      end

      context "with other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::1"),
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"),
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::180")
          )
        end

        it "modifies the record set to remove our record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::1" },
                            { value: "2001:DB8::42" },
                            { value: "2001:DB8::180" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::1" },
                            { value: "2001:DB8::180" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"))
        end
      end

      context "with our record already gone" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::1"),
            DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::180")
          )
        end

        it "makes a no-op request to make sure everything is up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::1" },
                            { value: "2001:DB8::180" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "AAAA",
                          ttl: 42,
                          resource_records: [
                            { value: "2001:DB8::1" },
                            { value: "2001:DB8::180" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :AAAA, "2001:db8::42"))
        end
      end
    end

    context "with a CNAME record" do
      context "with no other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42")
          )
        end

        it "deletes the record set" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host42.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42"))
        end
      end

      context "with other records in the set" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host1"),
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42"),
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host180")
          )
        end

        it "modifies the record set to remove our record" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host1.example.com" },
                            { value: "host42.example.com" },
                            { value: "host180.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host1.example.com" },
                            { value: "host180.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42"))
        end
      end

      context "with our record already gone" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host1"),
            DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host180")
          )
        end

        it "makes a no-op request to make sure everything is up-to-date" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host1.example.com" },
                            { value: "host180.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "flingle.example.com",
                          type: "CNAME",
                          ttl: 42,
                          resource_records: [
                            { value: "host1.example.com" },
                            { value: "host180.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("flingle", 42, :CNAME, "host42"))
        end
      end
    end

    context "with a SRV record" do
      context "with other SRV records present" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host1"),
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host2")
          )
        end

        it "deletes our SRV record from the record set" do
          expect(r53).to receive(:change_resource_record_sets)
            .with(change_batch: {
                    changes: [
                      {
                        action: "DELETE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 8080 host1.example.com" },
                            { value: "0 0 8080 host2.example.com" }
                          ]
                        }
                      },
                      {
                        action: "CREATE",
                        resource_record_set: {
                          name: "faff._http._tcp.example.com",
                          type: "SRV",
                          ttl: 42,
                          resource_records: [
                            { value: "0 0 8080 host1.example.com" }
                          ]
                        }
                      }
                    ]
                  },
                  hosted_zone_id: "Z3M3LMPEXAMPLE"
                 )
            .and_call_original
          expect(r53).to_not receive(:list_resource_record_sets)

          backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host2"))
        end

        context "when faced with an InvalidChangeBatch error" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host1"),
              DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host3"),
              DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host22")
            )
          end

          let(:route53_stubs) do
            already_called = false
            {
              list_resource_record_sets: route53_response_fixture("faff_srv"),
              change_resource_record_sets: ->(context) do
                unless already_called
                  already_called = true
                  'InvalidChangeBatch'
                else
                  {
                    change_info: {
                      id: "xyzzy",
                      status: "PENDING",
                      submitted_at: Time.now
                    }
                  }
                end
              end
            }
          end

          it "refreshes the cache and tries the change again" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 80 faff.host1.example.com" },
                              { value: "0 0 8080 host3.example.com" },
                              { value: "0 0 80 faff.host22.example.com" },
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 8080 host3.example.com" },
                              { value: "0 0 80 faff.host22.example.com" },
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   ).and_call_original.ordered
            expect(backend).to receive(:sleep).with(a_value_between(0, 2))
            expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff._http._tcp.example.com", start_record_type: "SRV", max_items: 1).and_call_original.ordered
            expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff._http._tcp.example.com", start_record_type: "TXT", max_items: 1).and_call_original.ordered
            expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "_http._tcp.example.com", start_record_type: "PTR", max_items: 1).and_call_original.ordered
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 80 faff.host1.example.com" },
                              { value: "0 0 8080 host3.example.com" }
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 8080 host3.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   )
              .and_call_original
            expect(r53).to_not receive(:list_resource_record_sets).ordered

            backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host1"))
          end

          context "that never resolves" do
            let(:route53_stubs) do
              {
                list_resource_record_sets: route53_response_fixture("faff_srv"),
                change_resource_record_sets: 'InvalidChangeBatch'
              }
            end

            it "retries for a while then gives up" do
              with_overridden_constant(DDNSSD::Backend::Route53::Retryable, :DEFAULT_RETRY_LIMIT, 42) do
                expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered

                41.times do
                  expect(backend).to receive(:sleep).with(a_value_between(0, 2))
                  # Refreshes the SRV, TXT, *and* PTR
                  3.times { expect(r53).to receive(:list_resource_record_sets).and_call_original.ordered }
                  expect(r53).to receive(:change_resource_record_sets).and_call_original.ordered
                end

                expect(logger).to receive(:error).ordered

                expect(r53).to_not receive(:list_resource_record_sets)
                expect(r53).to_not receive(:change_resource_record_sets)

                backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 80, "faff.host1"))
              end
            end
          end
        end
      end

      context "with no other SRV records present" do
        before(:each) do
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host1")
          )
          backend.instance_variable_get(:@record_cache).set(
            DDNSSD::DNSRecord.new("faff._http._tcp", 42, :TXT, "something funny")
          )
        end

        context "with no other PTR records" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp")
            )
          end

          it "deletes the SRV, TXT, and PTR record sets" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 8080 host1.example.com" }
                            ]
                          }
                        },
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "TXT",
                            ttl: 42,
                            resource_records: [
                              { value: '"something funny"' }
                            ]
                          }
                        },
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   )
              .and_call_original
            expect(r53).to_not receive(:list_resource_record_sets)

            backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host1"))
          end
        end

        context "with other PTR records" do
          before(:each) do
            backend.instance_variable_get(:@record_cache).set(
              DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "blargh._http._tcp"),
              DDNSSD::DNSRecord.new("_http._tcp", 42, :PTR, "faff._http._tcp")
            )
          end

          it "deletes the SRV and TXT record sets, and prunes our record from the PTR record set" do
            expect(r53).to receive(:change_resource_record_sets)
              .with(change_batch: {
                      changes: [
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "SRV",
                            ttl: 42,
                            resource_records: [
                              { value: "0 0 8080 host1.example.com" }
                            ]
                          }
                        },
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "faff._http._tcp.example.com",
                            type: "TXT",
                            ttl: 42,
                            resource_records: [
                              { value: '"something funny"' }
                            ]
                          }
                        },
                        {
                          action: "DELETE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "blargh._http._tcp.example.com" },
                              { value: "faff._http._tcp.example.com" }
                            ]
                          }
                        },
                        {
                          action: "CREATE",
                          resource_record_set: {
                            name: "_http._tcp.example.com",
                            type: "PTR",
                            ttl: 42,
                            resource_records: [
                              { value: "blargh._http._tcp.example.com" }
                            ]
                          }
                        }
                      ]
                    },
                    hosted_zone_id: "Z3M3LMPEXAMPLE"
                   )
              .and_call_original
            expect(r53).to_not receive(:list_resource_record_sets)

            backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host1"))
          end

          context "when faced with an InvalidChangeBatch error" do
            let(:route53_stubs) do
              already_called = false
              {
                list_resource_record_sets: ->(context) do
                  case [context.params[:start_record_name], context.params[:start_record_type]]
                  when ["faff._http._tcp.example.com", "SRV"]
                    route53_response_fixture("faff_srv_host1")
                  when ["faff._http._tcp.example.com", "TXT"]
                    route53_response_fixture("faff_txt")
                  when ["_http._tcp.example.com", "PTR"]
                    route53_response_fixture("http_ptr_with_faff")
                  else
                    'WhatTheHellHero'
                  end
                end,
                change_resource_record_sets: ->(context) do
                  unless already_called
                    already_called = true
                    'InvalidChangeBatch'
                  else
                    {
                      change_info: {
                        id: "xyzzy",
                        status: "PENDING",
                        submitted_at: Time.now
                      }
                    }
                  end
                end
              }
            end

            it "refreshes the cache and tries the change again" do
              expect(r53).to receive(:change_resource_record_sets)
                .with(hosted_zone_id: "Z3M3LMPEXAMPLE",
                      change_batch: {
                        changes: [
                          {
                            action: "DELETE",
                            resource_record_set: {
                              name: "faff._http._tcp.example.com",
                              type: "SRV",
                              ttl: 42,
                              resource_records: [
                                { value: "0 0 8080 host1.example.com" }
                              ]
                            }
                          },
                          {
                            action: "DELETE",
                            resource_record_set: {
                              name: "faff._http._tcp.example.com",
                              type: "TXT",
                              ttl: 42,
                              resource_records: [
                                { value: '"something funny"' }
                              ]
                            }
                          },
                          {
                            action: "DELETE",
                            resource_record_set: {
                              name: "_http._tcp.example.com",
                              type: "PTR",
                              ttl: 42,
                              resource_records: [
                                { value: "blargh._http._tcp.example.com" },
                                { value: "faff._http._tcp.example.com" }
                              ]
                            }
                          },
                          {
                            action: "CREATE",
                            resource_record_set: {
                              name: "_http._tcp.example.com",
                              type: "PTR",
                              ttl: 42,
                              resource_records: [
                                { value: "blargh._http._tcp.example.com" }
                              ]
                            }
                          }
                        ]
                      }
                     ).and_call_original.ordered
              expect(backend).to receive(:sleep).with(a_value_between(0, 2))
              expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff._http._tcp.example.com", start_record_type: "SRV", max_items: 1).and_call_original.ordered
              expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "faff._http._tcp.example.com", start_record_type: "TXT", max_items: 1).and_call_original.ordered
              expect(r53).to receive(:list_resource_record_sets).with(hosted_zone_id: "Z3M3LMPEXAMPLE", start_record_name: "_http._tcp.example.com", start_record_type: "PTR", max_items: 1).and_call_original.ordered
              expect(r53).to receive(:change_resource_record_sets)
                .with(hosted_zone_id: "Z3M3LMPEXAMPLE",
                      change_batch: {
                        changes: [
                          {
                            action: "DELETE",
                            resource_record_set: {
                              name: "faff._http._tcp.example.com",
                              type: "SRV",
                              ttl: 42,
                              resource_records: [
                                { value: "0 0 8080 host1.example.com" }
                              ]
                            }
                          },
                          {
                            action: "DELETE",
                            resource_record_set: {
                              name: "faff._http._tcp.example.com",
                              type: "TXT",
                              ttl: 42,
                              resource_records: [
                                { value: '"something \"funny\""' }
                              ]
                            }
                          },
                          {
                            action: "DELETE",
                            resource_record_set: {
                              name: "_http._tcp.example.com",
                              type: "PTR",
                              ttl: 42,
                              resource_records: [
                                { value: "xyzzy._http._tcp.example.com" },
                                { value: "argle._http._tcp.example.com" },
                                { value: "faff._http._tcp.example.com" }
                              ]
                            }
                          },
                          {
                            action: "CREATE",
                            resource_record_set: {
                              name: "_http._tcp.example.com",
                              type: "PTR",
                              ttl: 42,
                              resource_records: [
                                { value: "xyzzy._http._tcp.example.com" },
                                { value: "argle._http._tcp.example.com" }
                              ]
                            }
                          }
                        ]
                      }
                     )
                .and_call_original
              expect(r53).to_not receive(:list_resource_record_sets).ordered

              backend.suppress_record(DDNSSD::DNSRecord.new("faff._http._tcp", 42, :SRV, 0, 0, 8080, "host1"))
            end
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
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("x", 60, :PTR, "faff.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "with an NS record" do
      it "logs an error" do
        expect { backend.suppress_record(DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")) }.to raise_error(DDNSSD::Backend::InvalidRequest)
      end
    end

    context "receiving any other error" do
      it "logs an error and gives up" do
        backend.instance_variable_get(:@record_cache).set(
          DDNSSD::DNSRecord.new("abcd1234.faff", 42, :A, "192.0.2.42")
        )
        expect(r53).to receive(:change_resource_record_sets).and_raise(RuntimeError)
        expect(logger).to receive(:error)

        backend.suppress_record(DDNSSD::DNSRecord.new("abcd1234.faff", 42, :A, "192.0.2.42"))
      end
    end
  end
end

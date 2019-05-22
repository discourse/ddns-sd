# frozen_string_literal: true
require_relative './spec_helper'

require 'ddnssd/system'
require 'ddnssd/backend/test_queue'
require 'ddnssd/backend/log'

describe DDNSSD::System do
  uses_logger

  let(:base_env) do
    {
      "DDNSSD_HOSTNAME"        => "speccy",
      "DDNSSD_BASE_DOMAIN"     => "example.com",
      "DDNSSD_BACKEND"         => "test_queue",
      "DDNSSD_HOST_IP_ADDRESS" => "192.0.2.42",
      "DOCKER_HOST"            => "unix:///var/run/test.sock",
    }
  end
  let(:env) { base_env }

  let(:system) { DDNSSD::System.new(env, logger: logger) }

  describe ".new" do
    it "passes the env+logger through to the config" do
      expect(DDNSSD::Config).to receive(:new).with(env, logger: logger).and_call_original

      DDNSSD::System.new(env, logger: logger)
    end

    context "with multiple backends" do
      let(:env) { base_env.merge("DDNSSD_BACKEND" => "test_queue,log") }

      it "instantiates both backends" do
        expect(DDNSSD::Backend::TestQueue).to receive(:new).with(instance_of(DDNSSD::Config))
        expect(DDNSSD::Backend::Log).to receive(:new).with(instance_of(DDNSSD::Config))

        system
      end
    end
  end

  describe "#config" do
    it "returns the config" do
      expect(system.config).to be_a(DDNSSD::Config)
    end
  end

  let(:mock_queue) { instance_double(Queue) }
  let(:mock_watcher) { instance_double(DDNSSD::DockerWatcher) }
  let(:mock_backend) { instance_double(DDNSSD::Backend::TestQueue) }
  let(:mock_log_backend) { instance_double(DDNSSD::Backend::Log) }

  before(:each) do
    allow(DDNSSD::DockerWatcher).to receive(:new).with(queue: mock_queue, config: instance_of(DDNSSD::Config)).and_return(mock_watcher)
    allow(Queue).to receive(:new).and_return(mock_queue)
    allow(mock_queue).to receive(:pop).and_return([:terminate])
    allow(mock_watcher).to receive(:run!)
    allow(DDNSSD::Backend::TestQueue).to receive(:new).with(instance_of(DDNSSD::Config)).and_return(mock_backend)
    allow(DDNSSD::Backend::Log).to receive(:new).with(instance_of(DDNSSD::Config)).and_return(mock_log_backend)
    allow(mock_queue).to receive(:push)
    allow(mock_queue).to receive(:empty?).and_return(true)
    allow(mock_watcher).to receive(:shutdown)
    allow(mock_backend).to receive(:publish_record)
    allow(mock_backend).to receive(:rest)
    allow(mock_log_backend).to receive(:publish_record)
    allow(mock_log_backend).to receive(:rest)
  end

  describe "#shutdown" do
    it "sends the special :terminate message" do
      expect(mock_queue).to receive(:push).with([:terminate])

      system.shutdown
    end

    it "tells the watcher to shutdown" do
      expect(mock_watcher).to receive(:shutdown)

      system.shutdown
    end
  end

  describe "#run" do
    before(:each) do
      # Stub this out for now, since reconcile_containers has its own tests
      allow(system).to receive(:reconcile_containers).and_return(nil)
    end

    describe "initialization" do
      it "creates a queue" do
        system.run

        expect(Queue).to have_received(:new)
      end

      it "listens on the queue" do
        system.run

        expect(mock_queue).to have_received(:pop)
      end

      it "fires up a docker watcher" do
        system.run

        expect(DDNSSD::DockerWatcher).to have_received(:new).with(queue: mock_queue, config: instance_of(DDNSSD::Config))
        expect(mock_watcher).to have_received(:run!)
      end

      it "publishes the host's IP address" do
        expect(mock_backend).to receive(:publish_record).with(DDNSSD::DNSRecord.new("speccy", 60, :A, "192.0.2.42"))

        system.run
      end

      context "with multiple backends" do
        let(:env) { base_env.merge("DDNSSD_BACKEND" => "test_queue,log") }

        it "publishes the host's IP address to all backends" do
          expect(mock_backend).to receive(:publish_record).with(DDNSSD::DNSRecord.new("speccy", 60, :A, "192.0.2.42"))
          expect(mock_log_backend).to receive(:publish_record).with(DDNSSD::DNSRecord.new("speccy", 60, :A, "192.0.2.42"))

          system.run
        end
      end

      it "reconciles containers" do
        expect(system).to receive(:reconcile_containers).with(mock_backend)

        system.run
      end

      context "with multiple backends" do
        let(:env) { base_env.merge("DDNSSD_BACKEND" => "test_queue,log") }

        it "reconciles all backends" do
          expect(system).to receive(:reconcile_containers).with(mock_backend)
          expect(system).to receive(:reconcile_containers).with(mock_log_backend)

          system.run
        end
      end

      context "if enable_metrics is true" do
        let(:env) { base_env.merge("DDNSSD_ENABLE_METRICS" => "yes") }
        let(:mock_metrics_server) { instance_double(Frankenstein::Server) }

        it "fires up the metrics server" do
          expect(Frankenstein::Server).to receive(:new).with(port: 9218, logger: logger, registry: instance_of(Prometheus::Client::Registry)).and_return(mock_metrics_server)
          expect(mock_metrics_server).to receive(:run)

          system.run
        end
      end
    end

    describe "processing message" do
      let(:mock_conn) { instance_double(Docker::Connection) }
      let(:docker_container) { container_fixture("published_port80") }

      before(:each) do
        # This one's for the container_fixture calls
        allow(Docker::Connection).to receive(:new).with("unix:///", {}).and_call_original
        # This is the real one
        allow(Docker::Connection).to receive(:new).with("unix:///var/run/test.sock", {}).and_return(mock_conn)

        allow(Docker::Container).to receive(:get).with("asdfasdfpub80", {}, mock_conn).and_return(docker_container)
      end

      describe ':started' do
        it "recreates records for containers that had crashed" do
          # crashed containers are ones that :died, but never :stopped.
          allow(logger).to receive(:warn).with("DDNSSD::System")
          crashed_container = DDNSSD::Container.new(docker_container, system.config, system)
          crashed_container.crashed = true
          system.instance_variable_get(:@containers)["asdfasdfpub80"] = crashed_container

          expect(mock_queue).to receive(:pop).and_return([:started, crashed_container.id])
          expect(crashed_container).to receive(:suppress_records).with(mock_backend)
          expect(crashed_container).to_not receive(:publish_records)

          new_ddnssd_container = DDNSSD::Container.new(docker_container, system.config, system)
          allow(DDNSSD::Container).to receive(:new).with(docker_container, system.config, system).and_return(new_ddnssd_container)
          expect(new_ddnssd_container).to receive(:publish_records).with(mock_backend)

          system.run

          expect(system.instance_variable_get(:@containers)["asdfasdfpub80"]&.crashed).to be_falsy
        end
      end

      context 'mocked DDNSSD::Container' do
        let(:ddnssd_container) { DDNSSD::Container.new(docker_container, system.config, system) }

        before(:each) do
          allow(DDNSSD::Container).to receive(:new).with(docker_container, system.config, system).and_return(ddnssd_container)
        end

        describe ":started" do
          it "tells the container to go publish itself" do
            expect(mock_queue).to receive(:pop).and_return([:started, "asdfasdfpub80"])
            expect(ddnssd_container).to receive(:publish_records).with(mock_backend)

            system.run
          end

          it "does nothing if docker says the container doesn't exist" do
            allow(Docker::Container).to receive(:get).with("destroyedalready", {}, mock_conn).and_raise(Docker::Error::NotFoundError)
            expect(mock_queue).to receive(:pop).and_return([:started, "destroyedalready"])
            expect(ddnssd_container).to_not receive(:publish_records).with(mock_backend)
            allow(logger).to receive(:warn).with("DDNSSD::System")
            system.run
          end

          context "with multiple backends" do
            let(:env) { base_env.merge("DDNSSD_BACKEND" => "test_queue,log") }

            it "tells the container to publish itself everywhere" do
              expect(mock_queue).to receive(:pop).and_return([:started, "asdfasdfpub80"])
              expect(ddnssd_container).to receive(:publish_records).with(mock_backend)
              expect(ddnssd_container).to receive(:publish_records).with(mock_log_backend)

              system.run
            end
          end
        end

        describe ":stopped" do
          it "records that the container was requested to stop" do
            system.instance_variable_get(:@containers)["asdfasdfpub80"] = ddnssd_container

            expect(mock_queue).to receive(:pop).and_return([:stopped, "asdfasdfpub80"])
            expect(ddnssd_container).to receive(:stopped=).with(true)

            system.run
          end

          it "handles a container that doesn't exist" do
            expect(mock_queue).to receive(:pop).and_return([:stopped, "destroyedalready"])
            allow(logger).to receive(:warn).with("DDNSSD::System")
            system.run
          end
        end

        describe ":died" do
          before(:each) do
            allow(ddnssd_container).to receive(:stopped).and_return(false)
          end

          context "with normal exit status" do
            it "tells the container to go suppress itself" do
              system.instance_variable_get(:@containers)["asdfasdfpub80"] = ddnssd_container

              expect(mock_queue).to receive(:pop).and_return([:died, "asdfasdfpub80", 0])
              expect(ddnssd_container).to receive(:suppress_records).with(mock_backend)

              system.run
            end

            it "handles a container that doesn't exist" do
              expect(mock_queue).to receive(:pop).and_return([:died, "destroyedalready", 0])
              expect(ddnssd_container).to_not receive(:suppress_records).with(mock_backend)
              allow(logger).to receive(:warn).with("DDNSSD::System")

              system.run
            end

            context "with multiple backends" do
              let(:env) { base_env.merge("DDNSSD_BACKEND" => "test_queue,log") }

              it "tells the container to suppress itself everywhere" do
                system.instance_variable_get(:@containers)["asdfasdfpub80"] = ddnssd_container

                expect(mock_queue).to receive(:pop).and_return([:died, "asdfasdfpub80", 0])
                expect(ddnssd_container).to receive(:suppress_records).with(mock_backend)
                expect(ddnssd_container).to receive(:suppress_records).with(mock_log_backend)

                system.run
              end
            end
          end

          context "with abnormal exit status" do
            it "does not suppress records" do
              system.instance_variable_get(:@containers)["asdfasdfpub80"] = ddnssd_container

              expect(mock_queue).to receive(:pop).and_return([:died, "asdfasdfpub80", 42])
              expect(ddnssd_container).to_not receive(:suppress_records)
              expect(ddnssd_container).to receive(:crashed=).with(true)
              expect(logger).to receive(:warn).with("DDNSSD::System")

              system.run
            end

            it "handles a container that doesn't exist" do
              expect(mock_queue).to receive(:pop).and_return([:died, "destroyedalready", 42])
              expect(ddnssd_container).to_not receive(:suppress_records).with(mock_backend)
              allow(logger).to receive(:warn).with("DDNSSD::System")

              system.run
            end
          end

          context "with abnormal exit status after being stopped" do
            it "suppresses records" do
              expect(ddnssd_container).to receive(:stopped).and_return(true)

              system.instance_variable_get(:@containers)["asdfasdfpub80"] = ddnssd_container

              expect(mock_queue).to receive(:pop).and_return([:died, "asdfasdfpub80", 42])
              expect(ddnssd_container).to receive(:suppress_records).with(mock_backend)

              system.run
            end

            context "with multiple backends" do
              let(:env) { base_env.merge("DDNSSD_BACKEND" => "test_queue,log") }

              it "tells the container to suppress itself everywhere" do
                expect(ddnssd_container).to receive(:stopped).and_return(true)
                system.instance_variable_get(:@containers)["asdfasdfpub80"] = ddnssd_container

                expect(mock_queue).to receive(:pop).and_return([:died, "asdfasdfpub80", 42])
                expect(ddnssd_container).to receive(:suppress_records).with(mock_backend)
                expect(ddnssd_container).to receive(:suppress_records).with(mock_log_backend)

                system.run
              end
            end
          end
        end

        describe ":suppress_all" do
          it "suppresses records from all containers, as well as 'shared' records" do
            system.instance_variable_get(:@containers)["asdfasdpub80"] = ddnssd_container
            expect(ddnssd_container).to receive(:suppress_records).with(mock_backend)
            expect(mock_backend).to receive(:suppress_shared_records)

            expect(mock_queue).to receive(:pop).and_return([:suppress_all])

            system.run
          end

          context "with multiple backends" do
            let(:env) { base_env.merge("DDNSSD_BACKEND" => "test_queue,log") }

            it "suppresses all records from both backends" do
              system.instance_variable_get(:@containers)["asdfasdfpub80"] = ddnssd_container

              expect(mock_queue).to receive(:pop).and_return([:suppress_all])
              expect(ddnssd_container).to receive(:suppress_records).with(mock_backend)
              expect(mock_backend).to receive(:suppress_shared_records)

              expect(ddnssd_container).to receive(:suppress_records).with(mock_log_backend)
              expect(mock_log_backend).to receive(:suppress_shared_records)

              system.run
            end
          end
        end
      end
    end

    describe "unknown message" do
      it "logs an error" do
        expect(mock_queue).to receive(:pop).and_return("whaddya mean this ain't a valid message?!?")

        expect(logger).to receive(:error)

        system.run
      end
    end
  end

  describe "#reconcile_containers" do
    let(:mock_conn) { instance_double(Docker::Connection) }
    let(:docker_containers) { [] }
    let(:dns_records) { [] }

    before(:each) do
      # This one's for the container_fixture calls
      allow(Docker::Connection).to receive(:new).with("unix:///", {}).and_call_original
      # This is the real one
      allow(Docker::Connection).to receive(:new).with("unix:///var/run/test.sock", {}).and_return(mock_conn)

      allow(Docker::Container).to receive(:all).with({}, mock_conn).and_return(docker_containers)
      allow(Docker::Container).to receive(:get).with("asdfasdfpub80", {}, mock_conn).and_return(container_fixture("published_port80"))
      allow(Docker::Container).to receive(:get).with("asdfasdfexposed80", {}, mock_conn).and_return(container_fixture("exposed_port80"))

      expect(mock_backend).to receive(:dns_records).and_return(dns_records)
      allow(mock_backend).to receive(:publish_record)
    end

    it "requests a current container list" do
      system.send(:reconcile_containers, mock_backend)

      expect(Docker::Container).to have_received(:all).with({}, mock_conn)
    end

    it "doesn't include containers that disappear between the all and the get" do
      expect(Docker::Container).to receive(:all).with({}, mock_conn).and_return(container_fixtures("published_port80", "published_port22", "exposed_port80"))
      expect(Docker::Container).to receive(:get).with("asdfasdfpub80", {}, mock_conn)
      expect(Docker::Container).to receive(:get).with("asdfasdfpub22", {}, mock_conn).and_raise(Docker::Error::NotFoundError)
      expect(Docker::Container).to receive(:get).with("asdfasdfexposed80", {}, mock_conn)

      system.send(:reconcile_containers, mock_backend)

      expect(system.instance_variable_get(:@containers).keys.sort).to eq(["asdfasdfexposed80", "asdfasdfpub80"])
    end

    context "when there's a new container" do
      let(:dns_records) { dns_record_fixtures("exposed_port80", "other_machine") + [DDNSSD::DNSRecord.new("example.com", 60, :NS, "ns1.example.com")] }
      let(:docker_containers) { container_fixtures("exposed_port80", "published_port80") }

      it "adds records for the new container" do
        dns_record_fixture("published_port80").each do |rr|
          expect(mock_backend).to receive(:publish_record).with(eq(rr)).ordered
        end

        system.send(:reconcile_containers, mock_backend)
      end
    end

    context "when a container has been removed" do
      let(:dns_records) { dns_record_fixtures("exposed_port80", "published_port80", "other_machine") }
      let(:docker_containers) { container_fixtures("published_port80") }

      it "removes the records from the removed container" do
        dns_record_fixture("exposed_port80").each do |rr|
          next if [Resolv::DNS::Resource::IN::TXT, Resolv::DNS::Resource::IN::PTR].include?(rr.data.class)

          expect(mock_backend).to receive(:suppress_record).with(eq(rr))
        end

        system.send(:reconcile_containers, mock_backend)
      end
    end

    context "when a container has changed" do
      let(:dns_records) { dns_record_fixtures("published_port80") }
      let(:docker_containers) { container_fixtures("published_port80") }

      before(:each) do
        dc = container_fixture("published_port80")
        dc.info["NetworkSettings"]["Ports"]["80/tcp"].first["HostPort"] = "1337"

        allow(Docker::Container).to receive(:get).with("asdfasdfpub80", {}, mock_conn).and_return(dc)
      end

      it "removes the obsolete record and adds a new one" do
        # There are TXT and PTR records that will be published, that we don't
        # care so much about
        allow(mock_backend).to receive(:publish_record).with(any_args)

        expect(mock_backend)
          .to receive(:suppress_record)
          .with(eq(DDNSSD::DNSRecord.new("pub80._http._tcp", 60, :SRV, 0, 0, 8080, "speccy")))
        expect(mock_backend)
          .to receive(:publish_record)
          .with(eq(DDNSSD::DNSRecord.new("pub80._http._tcp", 60, :SRV, 0, 0, 1337, "speccy")))

        system.send(:reconcile_containers, mock_backend)
      end
    end

    context "when DDNSSD_RECORD_TTL has changed" do
      let(:env) { base_env.merge("DDNSSD_RECORD_TTL" => "42") }
      let(:dns_records) { dns_record_fixtures("published_port80") }
      let(:docker_containers) { container_fixtures("published_port80").map { |dc| DDNSSD::Container.new(dc, system.config, system) } }

      it "removes the records with the wrong TTL and adds new ones with the right TTL" do
        dns_record_fixture("published_port80").each do |rr|
          next if [Resolv::DNS::Resource::IN::TXT, Resolv::DNS::Resource::IN::PTR].include?(rr.data.class)

          expect(mock_backend).to receive(:suppress_record).with(eq(rr))
        end

        dns_record_fixture("published_port80").each do |rr|
          rr.instance_variable_set(:@ttl, 42)
          expect(mock_backend).to receive(:publish_record).with(eq(rr))
        end

        system.send(:reconcile_containers, mock_backend)
      end
    end
  end
end

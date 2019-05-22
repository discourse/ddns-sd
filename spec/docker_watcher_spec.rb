# frozen_string_literal: true
require_relative './spec_helper'
require 'logger'
require 'yaml'

require 'ddnssd/config'
require 'ddnssd/docker_watcher'

describe DDNSSD::DockerWatcher do
  uses_logger

  def test_event(type: "container", action:, id:, time: 987654321, exitCode: nil)
    actor = if exitCode
      Docker::Event::Actor.new(ID: id, Attributes: { "exitCode" => exitCode.to_s })
    else
      Docker::Event::Actor.new(ID: id)
    end

    Docker::Event.new(Type: type, Action: action, id: id, time: time, Actor: actor)
  end

  let(:env) do
    {
      "DDNSSD_BASE_DOMAIN" => "example.com",
      "DDNSSD_BACKEND"     => "test_queue",
      "DDNSSD_HOSTNAME"    => "speccy",
      "DOCKER_HOST"        => "unix:///var/run/test.sock"
    }
  end
  let(:config) { DDNSSD::Config.new(env, logger: logger) }

  let(:queue)   { Queue.new }
  let(:watcher) { DDNSSD::DockerWatcher.new(queue: queue, config: config) }

  describe ".new" do
    it "takes a queue and a docker socket URL" do
      expect(watcher).to be_a(DDNSSD::DockerWatcher)
    end
  end

  describe "#run" do
    let(:mock_conn) { instance_double(Docker::Connection) }

    before(:each) do
      allow(Docker::Connection).to receive(:new).with("unix:///var/run/test.sock", read_timeout: 3600).and_return(mock_conn)

      # I'm a bit miffed we have to do this; to my mind, a double should
      # lie a little
      allow(mock_conn).to receive(:is_a?).with(Docker::Connection).and_return(true)
      allow(Docker::Event).to receive(:since).and_raise(DDNSSD::DockerWatcher::Terminate)
      allow(Time).to receive(:now).and_return(1234567890)
    end

    it "connects to the specified socket with a long read timeout" do
      watcher.run

      expect(Docker::Connection).to have_received(:new).with("unix:///var/run/test.sock", read_timeout: 3600)
    end

    it "watches for events since the startup time" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn)

      watcher.run
    end

    it "emits a started event when a container is started" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "start", id: "asdfasdfpub80"))

      watcher.run

      expect(queue.length).to eq(1)
      item = queue.pop

      expect(item.first).to eq(:started)
      expect(item.last).to eq("asdfasdfpub80")
    end

    it "emits a stopped when a container is deliberately stopped" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "kill", id: "asdfasdfpub80"))

      watcher.run

      expect(queue.length).to eq(1)
      item = queue.pop

      expect(item.first).to eq(:stopped)
      expect(item.last).to eq("asdfasdfpub80")
    end

    it "emits a died, with an exit code, when a container fails to proceed" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "die", id: "asdfasdfpub80", exitCode: 42))

      watcher.run

      expect(queue.length).to eq(1)
      item = queue.pop

      expect(item).to eq([:died, "asdfasdfpub80", 42])
    end

    it "ignores uninteresting events" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(type: "container", action: "spindle", id: "zomg"))

      watcher.run

      expect(queue.length).to eq(0)
    end

    it "continues where it left off after timeout" do
      # This is the first round of Event calls; get an event and then timeout
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_yield(test_event(action: "create", id: "nope")).and_raise(Docker::Error::TimeoutError)
      # This is the retry, and terminate
      expect(Docker::Event).to receive(:since).with(987654321, {}, mock_conn).and_raise(DDNSSD::DockerWatcher::Terminate)

      watcher.run
    end

    it "delays then retries on socket error" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(Excon::Error::Socket)
      expect(watcher).to receive(:sleep).with(1)
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(DDNSSD::DockerWatcher::Terminate)

      watcher.run
    end

    it "logs unknown exceptions in the event processing loop" do
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(RuntimeError, "ZOMG")
      expect(logger).to receive(:error)
      expect(watcher).to receive(:sleep).with(1)
      expect(Docker::Event).to receive(:since).with(1234567890, {}, mock_conn).and_raise(DDNSSD::DockerWatcher::Terminate)

      watcher.run
    end

    it "logs an error and terminates on Docker connection failure" do
      expect(Docker::Connection).to receive(:new).and_raise(RuntimeError)
      expect(logger).to receive(:error)
      expect(queue).to receive(:push).with([:terminate])

      watcher.run
    end
  end
end

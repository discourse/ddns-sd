# frozen_string_literal: true
require_relative './spec_helper.rb'

require 'filtered_debug_logger'

describe FilteredDebugLogger do
  let(:logger) { Logger.new("/dev/null") }
  let(:logdev) { logger.instance_variable_get(:@logdev) }

  it "accepts a list of prognames to permit" do
    expect { logger.permitted_prognames = ["x", "y"] }.to_not raise_error
  end

  context "without a specified list of prognames" do
    it "works normally with severity info" do
      logger.level = Logger::INFO
      expect(logdev).to receive(:write).exactly(4).times

      # Shouldn't be written due to severity constraint
      logger.debug("x") { "ohai!" }

      # Should be written
      logger.info("x") { "ohai!" }
      logger.warn("x") { "ohai!" }
      logger.error("x") { "ohai!" }
      logger.fatal("x") { "ohai!" }
    end

    it "works normally with severity debug" do
      logger.level = Logger::DEBUG
      expect(logdev).to receive(:write).exactly(5).times

      # Should be written
      logger.debug("x") { "ohai!" }
      logger.info("x") { "ohai!" }
      logger.warn("x") { "ohai!" }
      logger.error("x") { "ohai!" }
      logger.fatal("x") { "ohai!" }
    end
  end

  context "with a specified list of prognames" do
    before :each do
      logger.permitted_prognames = ["x", "y"]
    end

    it "writes all info+higher log messages regardless of progname" do
      logger.level = Logger::DEBUG
      expect(logdev).to receive(:write).exactly(5).times

      # Should be written
      logger.info("x") { "ohai!" }
      logger.info("a") { "ohai!" }
      logger.warn("b") { "ohai!" }
      logger.error("c") { "ohai!" }
      logger.fatal("d") { "ohai!" }
    end

    it "writes only the debug messages for the given prognames" do
      logger.level = Logger::DEBUG
      expect(logdev).to receive(:write).exactly(2).times

      # Should be written
      logger.debug("x") { "ohai!" }
      logger.debug("y") { "ohai!" }

      # Shouldn't be written due to progname constraint
      logger.debug("a") { "ohai!" }
      logger.debug("b") { "ohai!" }
      logger.debug("c") { "ohai!" }
    end

    it "writes no debug messages if severity isn't debug" do
      logger.level = Logger::INFO
      expect(logdev).to receive(:write).exactly(3).times

      # Should be written
      logger.info("x") { "ohai!" }
      logger.info("a") { "ohai!" }
      logger.warn("b") { "ohai!" }

      # Shouldn't be written due to severity constraint
      logger.debug("x") { "ohai!" }
      logger.debug("y") { "ohai!" }
      logger.debug("a") { "ohai!" }
    end
  end
end

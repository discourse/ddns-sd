# frozen_string_literal: true
require 'logger'

module ExampleGroupMethods
  def uses_logger
    let(:logger) { instance_double(Logger, 'mock') }

    before(:each) do
      allow(logger).to receive(:debug).with(instance_of(String))
      allow(logger).to receive(:info).with(instance_of(String))
    end
  end
end

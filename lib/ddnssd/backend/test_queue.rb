# frozen_string_literal: true
require 'ddnssd/backend'

module DDNSSD
  class Backend
    class TestQueue < Backend
      def initialize(config)
      end

      def dns_records
      end

      def publish_record(*args)
      end

      def suppress_record(*args)
      end
    end
  end
end

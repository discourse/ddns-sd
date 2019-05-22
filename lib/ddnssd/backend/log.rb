# frozen_string_literal: true
require 'ddnssd/backend'

module DDNSSD
  class Backend
    class Log < Backend
      def initialize(config)
        @logger = config.logger
        @shared_records = {}
      end

      def dns_records
        []
      end

      def publish_record(*args)
        @logger.info("DDNSSD::Backend::Log") { "publish:  #{args.inspect}" }
      end

      def suppress_record(*args)
        @logger.info("DDNSSD::Backend::Log") { "suppress: #{args.inspect}" }
      end
    end
  end
end

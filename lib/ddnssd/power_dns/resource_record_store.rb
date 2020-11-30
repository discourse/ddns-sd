# frozen_string_literal: true

module DDNSSD
  module PowerDNS
    class ResourceRecordStore

      def initialize(backend, base_domain, logger)
        @backend = backend
        @base_domain = base_domain
        @logger = logger
        @domain_id = @backend.db.query_single(
          "SELECT id FROM domains WHERE name = :domain_name LIMIT 1",
          domain_name: @base_domain
        ).first
      end

      def lookup(filters = {})
        builder = @backend.db.build(
          "SELECT CAST(id AS TEXT), name, type, content, ttl FROM records /*where*/"
        )
        builder.where("domain_id = ?", @domain_id)
        filters.select { |k| [:name, :type, :content].include?(k) }.each do |col, value|
          builder.where("#{col} = ?", col == :name ? value.downcase : value.to_s)
        end
        builder.query
      end

      def add(dns_record)
        existing = lookup(
          name: dns_record.name, type: dns_record.type, content: dns_record.value
        )
        if existing.size == 0
          @backend.db.exec(
            "INSERT INTO records (domain_id, name, ttl, type, content, change_date)
            VALUES (:domain_id, :name, :ttl, :type, :content, :change_date)",
            domain_id: @domain_id,
            name: dns_record.name.downcase,
            ttl: dns_record.ttl,
            type: dns_record.type.to_s.upcase,
            content: dns_record.value,
            change_date: Time.now.to_i
          )
        else
          @logger.warn(progname) { "Record already exists. Not adding. #{dns_record.inspect}" }
          0
        end
      end

      def remove(dns_record)
        @backend.db.exec(
          "DELETE FROM records
               WHERE domain_id = :domain_id
                 AND name = :name
                 AND type = :type
                 AND content = :content",
          domain_id: @domain_id,
          name: dns_record.name,
          type: dns_record.type.to_s.upcase,
          content: dns_record.value
        )
      end

      def remove_with(name:, type:, content: nil)
        filters = { type: type&.to_s&.upcase, name: name, content: content }
        builder = @backend.db.build("DELETE FROM records /*where*/")
        builder.where("domain_id = ?", @domain_id)
        filters.each do |col, value|
          builder.where("#{col} = ?", value.to_s) if value
        end
        builder.exec
      end

      def upsert(dns_record)
        begin
          @backend.db.exec('BEGIN')
          remove_with(type: dns_record.type, name: dns_record.name)
          count = add(dns_record)
          @backend.db.exec('COMMIT')
          count
        rescue => ex
          @backend.db.exec('ROLLBACK')
          raise ex
        end
      end

      def all
        @backend.db.query(
          "SELECT name, ttl, type, content
             FROM records
            WHERE domain_id = ?
              AND type IN (?)",
          @domain_id,
          %w{A AAAA SRV PTR TXT CNAME}
        )
      end

      private

      def progname
        @logger_progname ||= "#{self.class.name}(#{@base_domain})"
      end

    end
  end
end

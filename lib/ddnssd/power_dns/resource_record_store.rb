# frozen_string_literal: true

module DDNSSD
  module PowerDNS
    class ResourceRecordStore

      def initialize(backend, base_domain, logger)
        @backend = backend
        @base_domain = base_domain
        @logger = logger
      end

      def lookup(filters = {})
        builder = @backend.db.build(
          "SELECT CAST(id AS TEXT), name, type, content, ttl FROM records /*where*/"
        )
        builder.where("domain_id = (SELECT id FROM domains where name = ? LIMIT 1)", @base_domain)
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
          args = {
            base_domain: @base_domain,
            name: dns_record.name.downcase,
            ttl: dns_record.ttl,
            type: dns_record.type.to_s.upcase,
            content: dns_record.value,
            change_date: Time.now.to_i
          }

          count = @backend.db.exec(<<~SQL, args)
            INSERT INTO records (domain_id, name, ttl, type, content, change_date)
            SELECT id, :name, :ttl, :type, :content, :change_date
            FROM domains
            WHERE name = :base_domain
            LIMIT 1
          SQL

          if count == 0
            @logger.warn(progname) { "Base domain changed, Not adding. #{dns_record.inspect}" }
          end

          count
        else
          @logger.warn(progname) { "Record already exists. Not adding. #{dns_record.inspect}" }
          0
        end
      end

      def remove(dns_record)
        @backend.db.exec(
          "DELETE FROM records
               WHERE domain_id IN (SELECT id FROM domains WHERE name = :base_domain)
                 AND name = :name
                 AND type = :type
                 AND content = :content",
          base_domain: @base_domain,
          name: dns_record.name,
          type: dns_record.type.to_s.upcase,
          content: dns_record.value
        )
      end

      def remove_with(name:, type:, content: nil)
        filters = { type: type&.to_s&.upcase, name: name, content: content }
        builder = @backend.db.build("DELETE FROM records /*where*/")
        builder.where("domain_id IN (SELECT id FROM domains WHERE name = ?)", @base_domain)
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
            WHERE domain_id in (SELECT id FROM domains WHERE name = ?)
              AND type IN (?)",
          @base_domain,
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

# frozen_string_literal: true

module PowerDNSHelper
  def power_dns_test_config
    {
      "DDNSSD_HOSTNAME" => "speccy",
      "DDNSSD_BACKEND" => "power_dns",
      "DDNSSD_BASE_DOMAIN" => "example.com",
      "DDNSSD_POWER_DNS_PG_HOST" => "localhost",
      "DDNSSD_POWER_DNS_PG_DBNAME" => "pdns_test",
      "DDNSSD_POWER_DNS_PG_USER" => "dnsadmin",
      "DDNSSD_POWER_DNS_PG_PASSWORD" => "dnsadminpw"
    }
  end

  def pdns_db_clean
    conn = PG.connect(host: 'localhost', dbname: 'pdns_test', user: 'dnsadmin', password: 'dnsadminpw')
    conn.exec("DELETE FROM records WHERE type != 'SOA'")
    conn.close
  end

  def preload_db
    pg_conn = PG.connect(
      host: 'localhost',
      dbname: 'pdns_test',
      user: 'dnsadmin',
      password: 'dnsadminpw'
    )

    conn = MiniSql::Connection.get(pg_conn)

    domain_id = conn.query_single(
      "SELECT id FROM domains WHERE name = ?",
      power_dns_test_config['DDNSSD_BASE_DOMAIN']
    )

    [
      ['abcd1234.flingle.example.com', 42, :A, '192.0.2.42'],
      ['flingle6.example.com', 42, :AAAA, '2001:DB8::42'],
      ['flinglec.example.com', 42, :CNAME, 'host42.example.com'],
      ['faff._http._tcp.example.com', 42, :SRV, '0 0 80 host1.example.com'],
      ['faff._http._tcp.example.com', 42, :SRV, '0 0 80 host2.example.com'],
      ['faff._http._tcp.example.com', 42, :TXT, 'funny'],
      ['_http._tcp.example.com', 42, :PTR, 'faff._http._tcp.example.com']
    ].each do |name, ttl, type, content|
      conn.exec(
        "INSERT INTO records (domain_id, name, ttl, type, content) VALUES (?, ?, ?, ?, ?)",
        domain_id, name, ttl, type.to_s, content
      )
    end

    pg_conn.close
  end
end

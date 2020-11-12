CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

BEGIN;

-- SET LOCAL default_sequenceam = 'bdr';

CREATE TABLE domains (
  id                    INT PRIMARY KEY DEFAULT TRUNC((2^31-1)*RANDOM()),
  name                  VARCHAR(255) NOT NULL,
  master                VARCHAR(128) DEFAULT NULL,
  last_check            INT DEFAULT NULL,
  type                  VARCHAR(6) NOT NULL,
  notified_serial       INT DEFAULT NULL,
  account               VARCHAR(40) DEFAULT NULL,
  CONSTRAINT c_lowercase_name CHECK (((name)::TEXT = LOWER((name)::TEXT)))
);

INSERT INTO domains (name, type) VALUES ('example.com', 'NATIVE');

CREATE UNIQUE INDEX name_index ON domains(name);

CREATE TABLE records (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  domain_id             INT REFERENCES domains(id) ON DELETE CASCADE,
  name                  VARCHAR(255) DEFAULT NULL,
  type                  VARCHAR(10) DEFAULT NULL,
  content               VARCHAR(65535) DEFAULT NULL,
  ttl                   INT DEFAULT NULL,
  prio                  INT DEFAULT NULL,
  change_date           INT DEFAULT NULL,
  disabled              BOOL DEFAULT 'f',
  ordername             VARCHAR(255),
  auth                  BOOL DEFAULT 't',
  CONSTRAINT c_lowercase_name CHECK (((name)::TEXT = LOWER((name)::TEXT)))
);

INSERT INTO records (domain_id, name, type, content) SELECT domains.id, 'example.com', 'SOA', 'example.com sysadmin.discourse.org 1 3600 600 604800 5' FROM domains WHERE domains.name = 'example.com';

CREATE INDEX rec_name_index ON records(name);
CREATE INDEX nametype_index ON records(name,type);
CREATE INDEX domain_id      ON records(domain_id);
CREATE INDEX recordorder    ON records (domain_id, ordername text_pattern_ops);

CREATE TABLE supermasters (
  ip                    INET NOT NULL,
  nameserver            VARCHAR(255) NOT NULL,
  account               VARCHAR(40) NOT NULL,
  PRIMARY KEY (ip, nameserver)
);


CREATE TABLE comments (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  domain_id             INT REFERENCES domains(id) ON DELETE CASCADE,
  name                  VARCHAR(255) NOT NULL,
  type                  VARCHAR(10) NOT NULL,
  modified_at           INT NOT NULL,
  account               VARCHAR(40) DEFAULT NULL,
  comment               VARCHAR(65535) NOT NULL,
  CONSTRAINT c_lowercase_name CHECK (((name)::TEXT = LOWER((name)::TEXT)))
);

CREATE INDEX comments_domain_id_idx ON comments(domain_id);
CREATE INDEX comments_name_type_idx ON comments(name, type);
CREATE INDEX comments_order_idx     ON comments(domain_id, modified_at);


CREATE TABLE domainmetadata (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  domain_id             INT REFERENCES domains(id) ON DELETE CASCADE,
  kind                  VARCHAR(32),
  content               TEXT
);

CREATE INDEX domainmetadata_idx ON domainmetadata (domain_id);

CREATE TABLE cryptokeys (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  domain_id             INT REFERENCES domains(id) ON DELETE CASCADE,
  flags                 INT NOT NULL,
  active                BOOL,
  content               TEXT
);

CREATE INDEX domainidindex ON cryptokeys(domain_id);

CREATE TABLE tsigkeys (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name                  VARCHAR(255),
  algorithm             VARCHAR(50),
  secret                VARCHAR(255),
  CONSTRAINT c_lowercase_name CHECK (((name)::TEXT = LOWER((name)::TEXT)))
);

CREATE UNIQUE INDEX namealgoindex ON tsigkeys(name, algorithm);

GRANT SELECT ON ALL TABLES IN SCHEMA public TO pdns;

GRANT SELECT ON domains TO dnsadmin;
GRANT SELECT, INSERT, DELETE ON records TO dnsadmin;

COMMIT;

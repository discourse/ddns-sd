Docker DNS-SD (ddns-sd) is a tool for publishing service information
gathered from Docker containers using the [DNS-Based Service Discovery
(DNS-SD) standard](https://tools.ietf.org/html/rfc6763).  DNS-SD is a
particular "pattern" of standard DNS records (`PTR`, `SRV`, and `TXT`
records) that allow for browsing and querying services on a network.  Whilst
it is often used in concert with [Multicast DNS
(mDNS)](https://tools.ietf.org/html/rfc6762), it works just as well with
regular DNS services, and that is how it is usually used in a Docker-based
system.


# How it Works

On startup, `ddns-sd` looks for DNS records that refer to the local machine
and its containers, and compares those against the records that should exist
based on the current set of running containers.  It creates and removes
records as required, to make the DNS align with the running containers.

After that, when containers are started and stopped, DNS records are created
or removed, as necessary, to reflect the containers that are in service.  If
a container stops unexpectedly (that is, it terminates with a non-zero exit
code, and was not stopped by explicit request), then the DNS records are not
removed, so that monitoring systems can detect that the container should
still exist, and alerts can be raised.

When `ddns-sd` itself is stopped (via the `TERM` signal, the default when
you ask to shutdown a container via `docker stop`) it removes all the DNS
records it manages, on the assumption that we may be shutting down the
machine, and all services should be deregistered.  If you know you're only
doing a restart, you can send the `SIGHUP` signal instead (via `docker kill
-s HUP ddns-sd`), and this will cause `ddns-sd` to leave all the DNS records
in place when it exits.


# Running

As you would expect from something that manages Docker containers, it is
available as a Docker image:

    docker run -v /var/run/docker.sock:/var/run/docker.sock \
        -e DDNSSD_HOSTNAME=$(hostname -s) \
        -e DDNSSD_BASE_DOMAIN=prod.example.com \
        -e DDNSSD_BACKEND=route53 \
        discourse/ddns-sd

The `-v` option is required to allow the container to listen for Docker
events like "container created" and "container removed", while the
environment variables shown above are the minimum configuration required
(see "Configuration", below, for all valid environment variables and their
meaning).

Note that `ddns-sd` runs as UID 1000, with GIDs 1000 and 999.  The socket
that you pass into the container must be accessible by one of those IDs.

You can also run `ddns-sd` without a container, for testing or whatever
takes your fancy, as follows:

    DDNSSD_HOSTNAME=$(hostname -s) \
    DDNSSD_BASE_DOMAIN=prod.example.com \
    DDNSSD_BACKEND=route53 \
    RUBYLIB=lib bin/ddns-sd

You're expected to have a running Docker installation with a socket at
`/var/run/docker.sock` that the executing user has access to, in order for
this to have any chance of success (or see the `DOCKER_HOST` environment
variable, below, for how to specify an alternate path).


# Configuration

All `ddns-sd` configuration is done via environment variables.  The
recognised variables are listed below.


## Required Environment Variables

All of these environment variables must be set when `ddns-sd` is started,
otherwise the program will immediately exit with an error message.

* **`DDNSSD_HOSTNAME`**

    A short (ie no dots) hostname that is used to construct various
    identifiers within the DNS records generated for services registered by
    this running instance of `ddns-sd`.  For example, the address records
    created for containers will be named
    `<container>.<DDNSSD_HOSTNAME>.<ZONE>`.

    This configuration item is considered required because figuring out what
    "the hostname" for a machine, whilst running in a container, is a
    process fraught with peril.

* **`DDNSSD_BASE_DOMAIN`**

    The FQDN under which all DNS records will be created and managed by
    default.  Addresses and aliases (CNAMEs) will be created directly under
    this name, whilst all discovery records (SRV, PTR, TXT) will be created
    under `_tcp.<DDNSSD_BASE_DOMAIN>` and `_udp.<DDNSSD_BASE_DOMAIN>`.

    Depending on your chosen backend, you may need to specify some sort of
    "zone identifier"; all hell may break loose if you set this to a value
    which isn't under the identified zone.

    You can override the default base domain for a specific backend by
    specifying a backend-specific `DDNSSD_<BACKEND>_BASE_DOMAIN` environment
    variable.


* **`DDNSSD_BACKEND`**

    The name of the DNS service plugin to use.  See "Supported DNS
    Services", below, for the list of valid values.


## Optional Environment Variables

The following environment variables are all optional, in that they have a
sensible default which works OK in at least some circumstances.

* **`DDNSSD_LOG_LEVEL`**

    *Default*: `"INFO"`

    Sets the level of logging emitted by default when `ddns-sd` starts up.
    Useful values are `"DEBUG"`, `"INFO"`, and `"ERROR"`.  See also the
    `USR1` and `USR2` signals, which can be used to change the log level
    at runtime.

* **`DDNSSD_DEBUG_MODULES`**

    *Default*: `""`

    This setting has no effect unless `DDNSSD_LOG_LEVEL=DEBUG`.

    If set to a non-empty string, this variable is interpreted as a
    comma-separated list of module names (as specified by the argument to
    `@logger.debug`) for which debug messages will be logged.  By default,
    all debug messages will be logged.

* **`DDNSSD_IPV6_ONLY`**

    *Default*: `"false"`

    If set to a true-ish string (`"yes"`, `"true"`, `"on"`, or `"1"`), then
    no A records will be created for any service record created by
    `ddns-sd`.  This is useful mostly for situations where you are running
    an IPv6-enabled network, and while the `GlobalIPv6Address` for your
    containers is routable, the `IPAddress` isn't.  Enabling this setting in
    that circumstance prevents unreachable IPv4 addresses from being
    published.

* **`DDNSSD_ENABLE_METRICS`**

    *Default*: `"false"`

    If set to a true-ish string (`"yes"`, `"true"`, `"on"`, or `"1"`), then
    a webserver will be started on port 9218, which will emit
    [Prometheus](https://prometheus.io/) metric data on `/metrics`.

* **`DDNSSD_RECORD_TTL`**

    *Default*: `60`

    *Valid Range*: `0`-`(2^31)-1`

    The TTL (time-to-live), in seconds, to set on all DNS resource records
    created by `ddns-sd` during operation.  The default, `60` seconds (one
    minute) is a reasonable middle ground between "hammering the DNS server
    into the ground with endless requests" and "why didn't you *tell* me
    hours ago all the servers had gone away?".

* **`DDNSSD_HOST_IP_ADDRESS`**

    *Default*: `""`

    The IPv4 address to use for published port registrations that don't
    specify an explicit IP address.

    If set to the empty string (the default), then published ports will not
    be registered unless an IP address was provided to the `--publish`
    argument to `docker run`.

* **`DOCKER_HOST`**

    *Default*: `"unix:///var/run/docker.sock"`

    Where `ddns-sd` should connect in order to communicate with Docker.

    This is mostly useful in situations where you want to put your Docker
    socket somewhere unusual.  If you change the `-v` option you pass to
    `docker run` when starting this container, or you're connecting to
    Docker via TCP, you'll need to change this, otherwise you can leave it
    alone.

* **`DDNSSD_VALIDATE_PORTS`**

    *Default*: `"true"`

    If set to a true-ish string (`"yes"`, `"true"`, `"on"`, or `"1"`), then
    service instances will only be registered if the labelled port is
    an exposed port in the container. Otherwise a warning will be logged,
    but the service instance will be registered.

* **`DDNSSD_CHECKPOINT_SECONDS`**

    *Default*: `0`

    If set to a positive integer value, then the service will reconcile the
    expected v. existing records on that schedule. Otherwise it only happens
    when the service is first started.

Each DNS service plugin may also have its own configuration variables that
can be used to configure backend-specific items; see the description of your
chosen service backend under "Support DNS Services", below, for more
details.


# Container Configuration

In order for a service to be registered for a container, the container
itself must opt-in to registration, by setting
[labels](https://docs.docker.com/engine/userguide/labels-custom-metadata/)
on the container.  Labels can be set on the image when it is built (and will
propagate into the running container), or set directly on the container at
runtime.


## Basic registration

To cause a service instance to be registered on behalf of a container, the
label `org.discourse.service._<name>.port` must exist, and the value must be
an exposed port in the container.

The `<name>` in the label must follow the rules for service names in
[RFC6335](https://tools.ietf.org/html/rfc6335), in particular [section
5.1](https://tools.ietf.org/html/rfc6335#section-5.1), which states:

> Valid service names are hereby normatively defined as follows:
>
> * MUST be at least 1 character and no more than 15 characters long
>
> * MUST contain only US-ASCII letters 'A' - 'Z' and
>   'a' - 'z', digits '0' - '9', and hyphens ('-', ASCII 0x2D or
>   decimal 45)
>
> * MUST contain at least one letter ('A' - 'Z' or 'a' - 'z')
>
> * MUST NOT begin or end with a hyphen
>
> * hyphens MUST NOT be adjacent to other hyphens
>
> [...]  Although service names may contain both upper-case and lower-case
> letters, case is ignored for comparison purposes, so both "http" and
> "HTTP" denote the same service.

The underscore is required in the tag name, but isn't part of the "service
name" itself (and therefore isn't one of the 15 characters).

Many existing protocols and services have an [IANA-registered service
name](https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml),
and you are encouraged to use them where possible.  If you do need to create
your own service name, you probably want to at least skim over [RFC6763
section 7](https://tools.ietf.org/html/rfc6763#section-7), as it contains a
lot of useful advice.  (Ignore section 7.1, though; we don't support
subtypes.)

The port number specified in the `...<port>` label is always the
*container-internal* port number (that is, the port inside the container
which the service will listen on).  Depending on various criteria, the port
that ends up in the `SRV` record may be different to this port number (more
on that under "Registering published ports", below).

In the simplest case, with an exposed port and a routable address to
register, the following DNS entries will be created:

* `<containername>.<DDNSSD_HOSTNAME>.<ZONE>  A/AAAA <address>`
* `<instance>._<servicename>._tcp.<ZONE> SRV 0 0 <port> <containername>.<DDNSSD_HOSTNAME>.<ZONE>.`
* `<instance>._<servicename>._tcp.<ZONE> TXT ""`
* `_<servicename>._tcp.<ZONE> PTR <instance>._<servicename>._tcp.<ZONE>.`

There are various special cases that will cause the DNS entries created to
be different to that above, covered in the below sections:

* To register a different service instance, see "Custom instance names".

* If you need to register multiple instances of a single service on one
  container, see "Registering multiple instance of a service".

* To vary the SRV record parameters, see "SRV record parameters".

* If you'd like [the `TXT` metadata
  record](https://tools.ietf.org/html/rfc6763#section-6) to be populated,
  see "TXT records".

* If you're registering a non-TCP service, and need that `_tcp` to be
  something else, see "Registering non-TCP services".

* If you have legacy non-DNS-SD-capable applications to support (don't we
  all?), see "CNAME aliases".

* Finally, if you're using port publishing (because your container IP
  addresses aren't routable), see "Registering published ports".

## Custom instance names

By default, the "instance" portion of the DNS-SD entry will be taken from
the name of the container.  If you wish to override it, you should set the
label `org.discourse.service._<name>.instance`, containing a string which
identifies the service instance to register.

The value of the `.instance` label can be any
"[Net-Unicode](https://tools.ietf.org/html/rfc5198)" text (UTF-8, basically)
up to and including 63 octets in length (as per [RFC6763 section
4.1.1](https://tools.ietf.org/html/rfc6763#section-4.1.1)).  In practice, I
happen to think you're inviting trouble if you use anything other than the
shortest practical sequence of letters, numbers, and hyphens (if for no
other reason than we can't guarantee that every DNS backend will behave in a
standards-compliant manner in the face of unexpected input), but the spec
lets you do it, so we will too.


## Registering multiple instances of a service

In some fairly uncommon cases, you may need to register multiple instances of
a service (on different ports) for the same container.  In that case, you
can use a numeric identifier after the service name to differentiate between
the different instances, like so:

    org.discourse.service._<service>.0.port     = "8080"
    org.discourse.service._<service>.0.instance = "foo"
    org.discourse.service._<service>.1.port     = "9090"
    org.discourse.service._<service>.1.instance = "bar"

This will register a SRV record for `foo._<service>._tcp.<domain>` on port
8080, and another SRV record for `bar._<service>._tcp.<domain>` on port
9090.

There is nothing special about "port" and "instance" in the example above;
any other per-service label you need (as described in later sections) can
also be applied with this numeric association pattern.


## Registering non-TCP services

The [DNS-SD RFC](https://tools.ietf.org/html/rfc6763#section-7) has some
slightly unorthodox ideas about whether a service resource record name
should have `_tcp` or `_udp` in it.  Essentially, the rules are: if it uses
TCP, it gets `_tcp`, and if it's *anything* else (whether that be UDP, SCTP,
QUIC, or anything else people come up with) it gets `_udp`.

For that reason, if you have a non-TCP service to register, you should set
this label in your container:

* `org.discourse.service._<name>.protocol = udp`

The possible values for the label are:

* **`tcp`**: the default.  A `_tcp` name will be registered.
* **`udp`**: A `_udp` name will be registered.
* **`both`**: A `_tcp` *and* a `_udp` name will be registered.

Note that there is the potential for unpleasantness if you set
`protocol=both` for a published port, but the addresses for the TCP and UDP
publishing records don't match.  This is because of the way SRV records work
-- they point to a *name*, not an *address*, so if you want to point
`foo._bar._tcp` at a different address from `foo._bar._udp`, you'd need
separate hostnames to point to.  Since this is the sort of pathological case
that should never be encouraged, this isn't supported.  The address provided
by the `tcp` publishing record will take precedence.


## Registering published ports

Under normal circumstances, `ddns-sd` will register the container listening
port in the `SRV` record it creates.  However, if your containers don't have
directly routable IP addresses, that's not very helpful, because no other
machine will be able to talk to the container.  For this reason, Docker has
the concept of "published" ports.  These are ports on the *host's* IP
address which will forward connections into your container.

If `ddns-sd` recognises that a port for which the service registration
labels exist has been marked as "published", then it assumes that the port
is not directly accessible, and will only register the service using the
host's publicly-available IP address, and the host port that has been
published.

To determine the publicly-available IP address to register, `ddns-sd` will
use the IP address given in the `--publish` argument (if given), or else the
address in the `DDNSSD_HOST_IP_ADDRESS` environment variable.  If neither of
these give an IP address worth using (ie not `INADDR_ANY`), then a warning
will be logged and no registration will be made for that port.


## SRV record parameters

The `priority` and `weight` attributes of a `SRV` record assist in load
balancing and failover situations, by allowing server selection to be
influenced.  See [RFC2782](https://tools.ietf.org/html/rfc2782) for the full
details of how these parameters work.

By default, `ddns-sd` sets these parameters both to `0`.  This means that
all servers will have an equal chance of being connected to.  If you need to
adjust these parameters, for whatever reason, use the following labels:

* `org.discourse.service._<service>.priority`
* `org.discourse.service._<service>.weight`

Both labels can be set to any numeric string between `0` and `65535`,
inclusive.


## TXT records

The [DNS-SD specification](https://tools.ietf.org/html/rfc6763#section-6)
provides a mechanism by which additional metadata can be provided to
consumers of a service instance, by means of a `TXT` record of the same name
as the service instance.  There are no specific rules for the interpretation
of this data, beyond some simple [key-value
semantics](https://tools.ietf.org/html/rfc6763#section-6.3).

To set a `TXT` record for a service registration, you must set sub-labels of
`org.discourse.service._<service>.tag`, where the portion of the label after
`..._<service>.tag.` is the key, and the label's value is the value of the
attribute.  For example, if you wanted to set keys `foo=bar` and
`baz=wombat`, you would set the following labels:

* `org.discourse.service._<service>.tag.foo = bar`
* `org.discourse.service._<service>.tag.baz = wombat`

Leaving the value of the label blank indicates an empty value.  If you wish
to set any "Attribute present, with no value" tags, use the
`org.discourse.service._<service>.tags` label, where each tag name is
separated by a newline (`0x0a`).

Keys must follow [the rules for keys in RFC6763 section
6.4](https://tools.ietf.org/html/rfc6763#section-6.4), specifically:

* MUST be at least one character long;
* SHOULD be no more than nine characters long;
* MUST be printable US-ASCII values (0x20-0x7E), excluding '=' (0x3D);
* Spaces are significant;
* Case is ignored.

Values are opaque binary data, and the total length of the key and its
associated value must be no more than 254 octets.

There is no explicit ordering of key/value pairs within the `TXT` record, with
the exception of [the `txtvers`
key](https://tools.ietf.org/html/rfc6763#section-6.7); if set, it is
automatically sorted to be the first key in the record.

Multiple TXT records for a single service instance are not supported at this
time.

In the event that two instances of `ddns-sd`, presumably running on
different machines, wish to set a `TXT` record to different values for the
same service instance FQDN, the behaviour is **EXPLICITLY UNDEFINED**.  At a
future time, we may wish to attach specific semantics to this situation; for
now, assume that if you give different containers in the same service
different metadata, *anything* could happen, and you shouldn't rely on any
specific behaviour that might happen to be in existence at present.  If you
feel that you need to rely on a specific behaviour, please submit a
well-tested, -documented, and explained PR, codifying whichever behaviour
you feel is appropriate.


## CNAME aliases

(This isn't part of the DNS-SD specification; it's just a useful addition)

For those legacy services which haven't gotten the memo about the wonders of
DNS-SD, `ddns-sd` provides a means by which DNS entries containing regular
`A`/`AAAA` records pointing to a container (or its host) can be created.

If you set a key `org.discourse.service._<service>.aliases` on your
registered service, in addition to the usual `A`/`AAAA`/`SRV`/`PTR`/`TXT`
records that are created, `CNAME` records will be created for each
comma-separated string in the label's value, referencing the appropriate
name that points to the container.

For example, if you set `org.discourse.service._<service>.aliases` to
`pgsql-master,some.funny.thing`, then `CNAME` records would be created
for `pgsql-master.<ZONE>` and `some.funny.thing.<ZONE>`.

The targets that will be placed in these records will be the same
as the `SRV` record targets for the service; this may be the
container IP addresses, or the host IP address, or a specific IP address
specified in the publication data, depending on
circumstances.  See "Basic registration" and "Registering published ports"
for more details about which addresses will be used when.

Be aware that there are all sorts of caveats with using aliases:

* If you're publishing ports, you'll need to be careful to publish to a port
  that the alias consumer will understand.

* Very little (read: no) validation is done on the values you pass to
  the `aliases` label; anything you do wrong will be reflected in broken or
  invalid CNAME records.

* If you have two machines both trying to register the same alias, they'll
  probably fight over it and the address will change back and forth, as CNAMEs
  are pure last-write-wins.

You may notice that these problems are all avoided if you just use `SRV`
records as `$DEITY` intended.  That is, after all, what we're all here for.


# Supported DNS Providers

In order for `ddns-sd` to be able to do anything useful, it has to be able
to manage records in a DNS zone.  Whilst the rest of the DNS ecosystem is
reasonably well standardised, dynamically updating DNS records is a
hodge-podge of proprietary, non-standard protocols, and one protocol ([DNS
UPDATE](https://tools.ietf.org/html/rfc2136)) that basically nobody uses,
despite having been on the standards track for 20 years.

Because there's a plethora of update protocols out there, developing a new
backend is intended to be fairly straightforward operation.  See the docs
for DDNSSD::Backend for the full speil.

Listed below are the existing supported providers.  Hopefully you find the
one you need.  If not, pull requests (with tests and documentation) welcome.


## AWS Route53

**`DDNSSD_BACKEND=route53`**

Maintains records in an [AWS Route53](https://aws.amazon.com/route53/) zone.
Currently only supports EC2 instance IAM authentications, every EC2 instance
running `ddns-sd` will need to have the following IAM policy attached:

    {
       "Version": "2012-10-17",
       "Statement": [
          {
             "Effect": "Allow",
             "Action": [
                "route53:GetHostedZone",
                "route53:ListResourceRecordSets"
                "route53:ChangeResourceRecordSets"
             ],
             "Resource": "arn:aws:route53:::hostedzone/<zone id>"
          }
       ]
    }

### Configuration

* **`DDNSSD_ROUTE53_ZONE_ID`**

    (required)

    The ID of the zone you wish all DNS records to be created in.  This is
    the 14-or-so character string that's under the "Hosted Zone ID" column
    in the Route53 zone list.

## Power DNS

**`DDNSSD_BACKEND=power_dns`**

Maintains records in a PostgreSQL database used by a [Power DNS](https://www.powerdns.com/) server.
The database schema should be compatible with the one found in db/pdns-schema.sql, with a
user having select privileges on the domains and records table, and select, insert, and delete
privileges on the records table.

### Configuration

* **`DDNSSD_POWER_DNS_PG_DBNAME`**

The PostgreSQL database name.

* **`DDNSSD_POWER_DNS_PG_USER`**

The PostgreSQL user with select privileges on the domains and records table, and select, insert,
and delete privileges on the records table.

* **`DDNSSD_POWER_DNS_PG_PASSWORD`**

The password for the above PostgreSQL user.


## Azure DNS

**`DDNSSD_BACKEND=azure`**

Maintains records in an [Azure](https://azure.microsoft.com/en-us/services/dns/) DNS Zone.
Currently only supports authentication through access tokens via `az account get-access-token`.

Every Azure VM running `ddns-sd` will need to have DNS Zone Contributor role on the DNS zone
as well as Network Contributor on the Resource Group that the DNS Zone belongs to.

The DNS Zone name is equal to the `DNSSD_BASE_DOMAIN`.

### Configuration

* **`DDNSSD_AZURE_RESOURCE_GROUP_NAME`**

    (required)

    The name of the resource group that owns the DNS Zone.


* **`DDNSSD_AZURE_ACCESS_TOKEN`**

    (required)

    An azure access token (in json format) - this is the output of `az account get-access-token`.


## Logging-only backend

**`DDNSSD_BACKEND=log`**

This is a debugging aid only, and is unlikely to be of much use to anyone in
the real world.  It simply logs all DNS change events as they happen in a
human-readable format.


# Signals

The `ddns-sd` command-line program (and hence the Docker container) accept
the following signals to control the running service:

* **`USR1`**: Increase the verbosity of the logging output, `ERROR` ->
  `WARN` -> `INFO` -> `DEBUG`.

* **`USR2`**: Decrease the verbosity of logging, `DEBUG` -> `INFO` -> `WARN`
  -> `ERROR`.  Errors are always logged.

* **`TERM`**: Terminate gracefully, withdrawing all DNS records for
  containers on the host.

* **`HUP`**: Terminate with intent to restart.  No DNS records are
  withdrawn.


# Instrumentation

In keeping with modern best practices, `ddns-sd` provides an extensive set
of metrics on its performance and operation.  To gain access to them, you'll
need to set the `DDNSSD_ENABLE_METRICS` environment variable to `true`; once
that's done, `ddns-sd` will listen on port 9218 for HTTP requests to
`/metrics`, and will respond with a Prometheus-compatible response
containing all of the metrics that have been collected.

Since the Prometheus format's built-in documentation capabilities are...
limited, to say the least, all of the available metrics and what they
represent are listed below.

## General metrics

* **`ddnssd_start_timestamp`** The Unix epoch timestamp at which this
  instance of `ddns-sd` was started, according to the system clock.  If the
  git commit ID of the running codebase can be determined (which it will be
  in the default Docker container), it will be set in the `git_revision`
  label on this metric, allowing you to see, for instance, if a given
  revision of `ddns-sd` is crashing frequently.

## DNS backend operations

These metrics count every "high-level" operation that the DNS backend
performs (publishing a new record to DNS, or suppressing an existing one).
Depending on the exact nature of the backend, there may be an arbitrary
number of *actual* operations against the data store performed (and those
lower-level operations should be instrumented separately).  This metric set
is to capture the aggregate details of operations against the DNS backend.

All these metrics are labelled with the operation being performed, `op`
(either `"publish"` or `"suppress"`), as well as the resource record type
being operated on, `rrtype` (one of `"A"`, `"AAAA"`, `"SRV"`, `"TXT"`,
`"PTR"`, or `"CNAME"`).

* **`ddnssd_backend_requests_total`**: How many "high-level" operations
  against the DNS backend have been started.  This includes any operations
  that may have failed (see `ddnssd_backend_exceptions_total`).

* **`ddnssd_backend_request_duration_seconds_{bucket,sum,count}`**:
  [Histogram metrics](https://prometheus.io/docs/practices/histograms/)
  measuring how long it takes to *successfully* complete a backend
  operation.  Unsuccessful operations (ones that raise an exception) are not
  counted here, because they typically take less time than successful
  operations, and you don't want your stats to look better than they are.

* **`ddnssd_backend_exceptions_total`**: How many exceptions have been
  raised by backend operations.  Any non-zero values in here are a cause for
  concern, and the exact details of the exceptions should be provided in the
  logs.

* **`ddnssd_backend_in_progress_count`**: How many backend operations are
  currently in progress.  Because of the way that `ddns-sd` works,
  `sum(ddnssd_backend_in_progress_count) by (instance)` should always be
  less than or equal to `1`.


## Route53 backend

The route53 backend layers its own instrumentation on top of the metrics
provided by `ddnssd_backend_*`, to give a more detailed picture of what's
going on when talking to Route53 itself.

These metrics are all labelled by the particular operation being performed,
one of `"list"` (get all records in the zone; should ideally only happen
once, at startup), `"get"` (refresh the cache for a single record set), or
`"change"` (apply a change to the DNS records).

* **`ddnssd_route53_requests_total`**: How many requests have been made to
  route53.

* **`ddnssd_route53_request_duration_seconds_{bucket,sum,count}`**:
  [Histogram metrics](https://prometheus.io/docs/practices/histograms/) of
  how long it took Route53 to respond to a request we made.  Only successful
  responses are counted here.

* **`ddnssd_route53_exceptions_total`**: How many requests resulted in our
  raising an exception because something was very wrong, labelled by the
  exception `class`.  Exception classes starting with `Aws::` are problems
  reported by AWS that we're not cleanly handling, while everything else is
  probably something we did.  Neither should ever happen, ideally, so you
  can check to see if they're non-zero and freak out.

* **`ddnssd_route53_in_progress_count`**: How many requests are currently
  in-progress to Route53.  Because of the way that `ddns-sd` works,
  `sum(ddnssd_route53_in_progress_count) by (instance)` should always be
  less than or equal to `1`.


## Docker events

We keep a running total of all events coming at us from Docker.  This can be
useful to figure out if a problem with changes not being propagated is
because Docker isn't sending the events (if the event count in `ddns-sd`
isn't going up) or in `ddns-sd` (if the event count is going up, but things
aren't changing).

* **`ddnssd_docker_event_total`**: How many events have been seen by
  `ddns-sd`.  Separated out by a `type` label, which is either `"started"`
  (container was started, and we should have created some DNS records),
  `"stopped"` (container was stopped, and we *probably* should have deleted
  some DNS records), or `"ignored"` (the event wasn't pertinent to
  `ddns-sd`).

* **`ddnssd_docker_event_exceptions_total`**: How many exceptions have been
  raised while handling events, labelled by the exception `class`.  This
  should never be a non-zero number, but if it is, the exception details,
  including a backtrace, should be in the logs.


## HTTP metrics server

It's not a complete instrumentation package unless the metrics server is
spitting out metrics.  Very meta.  Note that, since the metrics are updated
*after* a request is processed, it doesn't include the request that
retrieves the metrics you're looking at.

* **`ddnssd_metrics_requests_total`**: How many requests have hit the metrics
  HTTP server.

* **`ddnssd_metrics_request_duration_seconds_{bucket,sum,count}`**: [Histogram
  metrics](https://prometheus.io/docs/practices/histograms/) for the time
  taken to service HTTP metrics server requests.

* **`ddnssd_metrics_exceptions_total`**: How many requests to the metrics
  server resulted in an unhandled exception being raised, labelled by
  exception class.  This should never have a non-zero number anywhere around
  it.

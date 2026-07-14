# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-07-13

### Security
- **Fix SSRF via egress filtering ([GHSA-4325-m2h3-7rwf](https://github.com/OpenFn/philter/security/advisories/GHSA-4325-m2h3-7rwf)).** Philter previously connected to any caller-supplied `:upstream` with no egress validation, allowing requests to loopback, RFC1918, link-local and cloud metadata (169.254.169.254 / IMDS) addresses, and was vulnerable to DNS rebinding. Deny-by-default egress filtering (`block_private_networks: true`) now rejects upstreams that resolve to private, loopback, link-local, CGNAT or otherwise internal ranges (IPv4 `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.168.0.0/16`, `240.0.0.0/4`; IPv6 `::`, `::1`, `fc00::/7`, `fe80::/10`, plus IPv4-mapped, IPv4-compatible and NAT64 forms unwrapped to their embedded IPv4 and re-checked). Blocking is on the resolved address tuples, not the URL literal, so octal/hex/decimal IP-encoding tricks are moot. A blocked address returns `403` with a static body; the resolved IP is logged server-side only, never returned to the client.
- **Require Mint `~> 1.9`** (was `~> 1.7`). Mint 1.9.1 is the lowest release clearing five 2026 advisories relevant to proxying: CRLF injection via an unvalidated HTTP method, HTTP response smuggling via lenient Content-Length parsing, unbounded buffering of chunked response bodies, HTTP/2 CONTINUATION flooding, and stream exhaustion via unenforced PUSH_PROMISE limits.

### Changed
- **Breaking**: Replaced the Finch transport with a Mint-direct "resolve-and-pin" transport (`Philter.Transport`). It resolves the upstream host once, validates every A/AAAA answer against the egress policy, and connects the socket to a validated IP tuple without ever re-resolving, while preserving the original hostname for the Host header, TLS SNI and certificate verification. This closes DNS rebinding. Host applications no longer need to supervise a Finch pool for Philter.
- The transport is raw HTTP/1 with no connection pooling, so every request opens a fresh connection.

### Added
- `Philter.Egress` module — resolves a hostname and validates the resolved addresses against the SSRF egress policy. Transport-agnostic; policy is supplied per call.
- `:block_private_networks` option (default `true`) — deny-by-default egress filtering for `proxy/2` and `ProxyPlug`.
- `:allowed_hosts` option (default `[]`) — opt-in escape hatch listing host strings that bypass the egress check, matched case-insensitively ignoring a trailing dot, for deliberately reaching internal hosts.
- `:dns_timeout` option (default `5_000` ms) — bounds upstream DNS resolution; on timeout the request is rejected with `504`. An unresolvable host returns `502`.

### Deprecated
- `:finch_name` option is deprecated and ignored — the transport no longer uses Finch, so host apps no longer need to supervise a Finch pool for Philter. Accepting it keeps existing callers from crashing.

## [0.3.0] - 2026-04-09

### Changed
- **Breaking**: All timing consolidated into `finished_result.timing` map — `finished_result.duration_us` replaced by `timing.total_us`, and `body_observation.duration_us` / `body_observation.time_to_first_byte_us` removed. Observations are now purely content metadata (hash, size, preview, body)

### Added
- `collect_timing: true` option for `proxy/2` enables per-phase timing capture (queue, connect, send, recv, idle_time, reused_connection) from HTTP client telemetry
- `Philter.Timing` module for telemetry-based phase timing with lazy global handler attachment

## [0.2.1] - 2026-03-11

### Fixed
- Ensure handler module is loaded before checking optional callback exports, fixing silent callback skip on first use ([`7b47409`](https://github.com/OpenFn/philter/commit/7b47409))

## [0.2.0] - 2026-03-11

### Added
- `:extra_headers` option for `proxy/2` and `ProxyPlug` — merge additional headers into the filtered outbound request, replacing existing headers with matching names ([`044e8fc`](https://github.com/OpenFn/philter/commit/044e8fc))
- `:strip_headers` option for `proxy/2` and `ProxyPlug` — remove named headers (case-insensitive) before forwarding ([`044e8fc`](https://github.com/OpenFn/philter/commit/044e8fc))
- Mutual exclusion validation: `:headers` cannot be combined with `:extra_headers` or `:strip_headers` (raises `ArgumentError`) ([`044e8fc`](https://github.com/OpenFn/philter/commit/044e8fc))
- Configurable logging via `:log_level` option — lifecycle events logged at the configured level, or suppressed with `false` ([`daa8657`](https://github.com/OpenFn/philter/commit/daa8657))

### Fixed
- Preserve explicit `host` header in caller-supplied `:headers` instead of always rewriting it ([`d2ac7b1`](https://github.com/OpenFn/philter/commit/d2ac7b1))
- Rewrite `host` header to match upstream URL in the default (filtered) path ([`475da4c`](https://github.com/OpenFn/philter/commit/475da4c))

## [0.1.0] - 2025-02-04

### Added
- Initial release (extracted from Spike)
- `Philter.proxy/2` for controller-based proxying
- `Philter.ProxyPlug` for router-level forwarding
- `Philter.Handler` behaviour for lifecycle callbacks
  - `handle_request_started/2` - Called before sending to upstream
  - `handle_response_started/2` - Called on first byte received (TTFB)
  - `handle_response_finished/2` - Called with complete observations
- Body observation with O(1) memory:
  - SHA256 hash computed incrementally
  - Byte size tracking
  - UTF-8 safe preview (first 64KB)
  - Timing information (TTFB, duration)
- Conditional body accumulation based on content-type and size
- Configurable timeouts, payload limits, content-type filtering
- Full test coverage with Bypass for upstream mocking

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-04-09

### Changed
- **Breaking**: `finished_result` replaces top-level `duration_us` with `timing` map containing `total_us` and per-phase breakdown fields (`queue_us`, `connect_us`, `send_us`, `recv_us`, `idle_time_us`, `reused_connection?`)
- **Breaking**: `body_observation` removes `duration_us` and `time_to_first_byte_us` — all timing is now consolidated in `finished_result.timing`; observations are purely content metadata (hash, size, preview, body)

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

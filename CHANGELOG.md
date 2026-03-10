# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

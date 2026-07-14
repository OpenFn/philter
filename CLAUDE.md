# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Philter is a streaming HTTP proxy library for Elixir with O(1) memory body observation. It forwards HTTP requests to upstream servers while capturing body observations (SHA256 hash, size, timing, preview) without buffering the full body in memory.

Core deps: `mint ~> 1.9`, `plug ~> 1.14`. Optional: `phoenix ~> 1.7`, `jason ~> 1.0`. Test: `bypass ~> 2.1`.

## Commands

```bash
mix test                          # Run all tests
mix test test/philter/observer_test.exs  # Run a single test file
mix test test/philter_test.exs:42    # Run a specific test by line number
mix format                        # Auto-format code
mix credo --strict                # Lint (strict mode, 120 char lines)
mix dialyzer                      # Static type analysis (slow first run, PLTs cached in priv/plts/)
mix lint                          # All quality checks: format --check-formatted + credo --strict + dialyzer
mix lint.fix                      # Auto-format (alias for mix format)
mix ci                            # Full CI pipeline: deps.get + compile --warnings-as-errors + lint + test
```

CI runs tests across Elixir 1.15–1.18 with OTP 25–27. Compile uses `--warnings-as-errors`.

## Architecture

**`Philter`** (`lib/philter.ex`) — Main entry point. `proxy/2` takes a `Plug.Conn` and options, resolves and validates the upstream against the egress policy (`Philter.Egress`), then streams the request to the validated address via `Philter.Transport` and streams the response back. Returns the conn with observations in `conn.private[:philter_request_observation]` and `conn.private[:philter_response_observation]`. Handles errors as 502/504 responses.

**`Philter.ProxyPlug`** — Plug for router-level forwarding. Delegates to `Philter.proxy/2`.

**`Philter.Egress`** — Deny-by-default SSRF egress gate. Resolves the upstream hostname and validates every resolved IP against a blocked-range set (RFC1918, loopback, link-local/cloud-metadata, CGNAT, reserved, plus IPv6 unique-local and link-local; IPv4-mapped and NAT64 forms are unwrapped and re-checked). Returns the validated addresses in resolution order for the transport to connect to (resolve-and-pin), or `{:error, reason}`. Transport-agnostic; policy comes from `:block_private_networks`, `:allowed_hosts` and `:dns_timeout`.

**`Philter.Transport`** — Mint-based HTTP/1 streaming transport. Connects directly to a caller-validated IP tuple without re-resolving the hostname (resolve-and-pin), while driving the Host header, TLS SNI and certificate hostname verification against the original hostname. Exposes a `stream_while/4` entry point that folds upstream events through the same reducer `Philter.proxy/2` uses. Interleaves reads between request-body chunk sends so an early upstream response cannot deadlock a large upload.

**`Philter.Handler`** — Behaviour for lifecycle callbacks. State threads through: `handle_request_started/2` → `handle_response_started/2` → `handle_response_finished/2`. Can reject requests before the upstream call. `handle_response_finished/2` is always called, even on error.

**`Philter.Observer`** — Single linked process spawned per request (replaced a previous 3-Agent design). Receives `:req_chunk`/`:resp_chunk`/`:resp_started`/`:finalize` messages. Fire-and-forget for chunks, synchronous for finalize (5s timeout).

**`Philter.Observation`** — Incremental body observation state machine. Streams SHA256 via `:crypto.hash_init/:hash_update/:hash_final`, captures first 64KB preview (UTF-8 safe), tracks size, conditionally accumulates full body based on content-type match + size limit.

**`Philter.Config`** — Resolves configuration by merging app env (`:philter`) with per-request overrides. Supports wildcard content-type patterns (e.g., `text/*`).

**`Philter.BodyStream`** — Adapts `Plug.Conn` body reading into a `{:stream, enumerable}` for the transport. Reads 64KB chunks.

**`Philter.UTF8`** — UTF-8 safe binary truncation for preview data.

### Request Flow

1. Resolve config (app env + per-request overrides) and handler
2. `handle_request_started/2` — can reject with `{:reject, status, body, state}`
3. Resolve and validate the upstream host via `Philter.Egress` — reject if any resolved IP falls in a blocked range (403), DNS times out (504), or nothing resolves (502)
4. Spawn linked Observer process
5. Build the transport request pinned to the validated addresses, stream request body via BodyStream (observer gets chunks)
6. `Philter.Transport.stream_while/4` — `:status` sets code, `:headers` filters hop-by-hop + starts chunked response, `:data` forwards chunks to client + observer
7. Finalize observer, call `handle_response_finished/2`, store observations in conn.private

### Key Design Decisions

- **Egress filtering** is deny-by-default: the upstream host is resolved once and every resolved address validated against internal ranges before connecting, then the transport pins to a validated IP and never re-resolves (closing the DNS-rebinding window) while preserving the hostname for the Host header, TLS SNI and certificate verification. `:allowed_hosts` is the escape hatch (still resolved, block check skipped); blocked resolutions return 403 and the resolved IP is logged server-side only, never to the client.
- **Hop-by-hop headers** (te, transfer-encoding, connection, etc.) are filtered from both request and response. Content-length is also removed from responses (chunked encoding used).
- **Custom `:headers` option** bypasses all request header filtering — headers are sent as-is.
- **Body accumulation** is conditional: only for matching content-types under `max_payload_size`. Preview and hash are always captured regardless.
- **Timeout errors** (`:timeout`, `:connect_timeout`, `{:closed, :timeout}`) return 504; all other errors return 502.

## Testing

Tests use `ExUnit` with `async: true` and `Bypass` for mocking upstream HTTP servers. Test support code is in `test/support/` (compiled via `elixirc_paths` in test env):

- `Philter.ConnCase` — CaseTemplate for Plug testing (no Phoenix dependency)
- `Philter.TestHelpers` — `bypass_upstream/0`, `test_handler/0`, `json_response/3`

`test/test_helper.exs` sets suite-wide app env, including `allowed_hosts` (`127.0.0.1`, `localhost`) so loopback Bypass servers pass the egress guard while it stays enabled for the rest of the suite.

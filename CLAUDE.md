# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Weir is a streaming HTTP proxy library for Elixir with O(1) memory body observation. It forwards HTTP requests to upstream servers while capturing body observations (SHA256 hash, size, timing, preview) without buffering the full body in memory.

Core deps: `finch ~> 0.18`, `plug ~> 1.14`. Optional: `phoenix ~> 1.7`, `jason ~> 1.0`. Test: `bypass ~> 2.1`.

## Commands

```bash
mix test                          # Run all tests
mix test test/weir/observer_test.exs  # Run a single test file
mix test test/weir_test.exs:42    # Run a specific test by line number
mix format                        # Auto-format code
mix credo --strict                # Lint (strict mode, 120 char lines)
mix dialyzer                      # Static type analysis (slow first run, PLTs cached in priv/plts/)
mix lint                          # All quality checks: format --check-formatted + credo --strict + dialyzer
mix lint.fix                      # Auto-format (alias for mix format)
mix ci                            # Full CI pipeline: deps.get + compile --warnings-as-errors + lint + test
```

CI runs tests across Elixir 1.15–1.18 with OTP 25–27. Compile uses `--warnings-as-errors`.

## Architecture

**`Weir`** (`lib/weir.ex`) — Main entry point. `proxy/2` takes a `Plug.Conn` and options, streams the request to upstream via `Finch.stream_while/4`, and streams the response back. Returns the conn with observations in `conn.private[:weir_request_observation]` and `conn.private[:weir_response_observation]`. Handles errors as 502/504 responses.

**`Weir.ProxyPlug`** — Plug for router-level forwarding. Delegates to `Weir.proxy/2`.

**`Weir.Handler`** — Behaviour for lifecycle callbacks. State threads through: `handle_request_started/2` → `handle_response_started/2` → `handle_response_finished/2`. Can reject requests before the upstream call. `handle_response_finished/2` is always called, even on error.

**`Weir.Observer`** — Single linked process spawned per request (replaced a previous 3-Agent design). Receives `:req_chunk`/`:resp_chunk`/`:resp_started`/`:finalize` messages. Fire-and-forget for chunks, synchronous for finalize (5s timeout).

**`Weir.Observation`** — Incremental body observation state machine. Streams SHA256 via `:crypto.hash_init/:hash_update/:hash_final`, captures first 64KB preview (UTF-8 safe), tracks size, conditionally accumulates full body based on content-type match + size limit.

**`Weir.Config`** — Resolves configuration by merging app env (`:weir`) with per-request overrides. Supports wildcard content-type patterns (e.g., `text/*`).

**`Weir.BodyStream`** — Adapts `Plug.Conn` body reading into a `{:stream, enumerable}` for Finch. Reads 64KB chunks.

**`Weir.UTF8`** — UTF-8 safe binary truncation for preview data.

### Request Flow

1. Resolve config (app env + per-request overrides) and handler
2. `handle_request_started/2` — can reject with `{:reject, status, body, state}`
3. Spawn linked Observer process
4. Build Finch request, stream request body via BodyStream (observer gets chunks)
5. `Finch.stream_while/4` — `:status` sets code, `:headers` filters hop-by-hop + starts chunked response, `:data` forwards chunks to client + observer
6. Finalize observer, call `handle_response_finished/2`, store observations in conn.private

### Key Design Decisions

- **Hop-by-hop headers** (te, transfer-encoding, connection, etc.) are filtered from both request and response. Content-length is also removed from responses (chunked encoding used).
- **Custom `:headers` option** bypasses all request header filtering — headers are sent as-is.
- **Body accumulation** is conditional: only for matching content-types under `max_payload_size`. Preview and hash are always captured regardless.
- **Timeout errors** (`:timeout`, `:connect_timeout`, `{:closed, :timeout}`) return 504; all other errors return 502.

## Testing

Tests use `ExUnit` with `async: true` and `Bypass` for mocking upstream HTTP servers. Test support code is in `test/support/` (compiled via `elixirc_paths` in test env):

- `Weir.ConnCase` — CaseTemplate for Plug testing (no Phoenix dependency)
- `Weir.TestHelpers` — `bypass_upstream/0`, `test_handler/0`, `json_response/3`

A test Finch pool (`Weir.TestFinch`) is started in `test/test_helper.exs`.

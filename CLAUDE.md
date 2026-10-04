# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Philter is a streaming HTTP proxy library for Elixir with O(1) memory body observation. It forwards HTTP requests to upstream servers while capturing body observations (SHA256 hash, size, preview and, for matching content types, the full body) without buffering the full body in memory.

Core deps: `mint ~> 1.11`, `plug ~> 1.14`. Optional: `jason ~> 1.0`. Test: `bypass ~> 2.1`, `x509 ~> 0.8` (self-signed certs for the TLS tests). Requires Elixir `~> 1.16`.

Philter depends on Plug, not Phoenix. Phoenix routers and controllers accept plain Plugs, so Phoenix apps can use `Philter.ProxyPlug` without Philter knowing Phoenix exists.

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

CI runs tests across Elixir 1.16–1.20 with OTP 26–29, with `compile --warnings-as-errors`. Format, credo and `mix deps.unlock --check-unused` run as a separate job, and dialyzer as another, both on the newest Elixir/OTP pair.

## Architecture

**`Philter`** (`lib/philter.ex`): main entry point. `proxy/2` takes a `Plug.Conn` and options, resolves and validates the upstream against the egress policy (`Philter.Egress`), then streams the request to the validated address via `Philter.Transport` and streams the response back. On success it returns the conn with observations in `conn.private[:philter_request_observation]` and `conn.private[:philter_response_observation]`. Failures become 403/502/504 responses. Header building (hop-by-hop filtering, host rewrite, `:strip_headers`, `:extra_headers`) lives here too.

**`Philter.ProxyPlug`**: Plug for router-level forwarding. `init/1` checks for `:upstream` and the header option clash, then `call/2` delegates to `Philter.proxy/2`.

**`Philter.Egress`**: deny-by-default SSRF egress gate. Resolves the upstream hostname (IPv4 and IPv6 in parallel tasks under one shared `:dns_timeout`) and validates every resolved IP against a blocked-range set (RFC1918, loopback, link-local/cloud-metadata, CGNAT, reserved, plus IPv6 unique-local and link-local). IPv6 forms that embed an IPv4 address (IPv4-mapped, IPv4-compatible, NAT64, 6to4, Teredo) are unwrapped and re-checked. Returns the validated addresses in resolution order for the transport to connect to, or `{:error, reason}`. Has no dependency on the transport or `Philter.Config`; policy comes in as options. A `:resolver` option replaces `:inet.getaddrs/2` so tests can feed it synthetic addresses.

**`Philter.Transport`** (internal): Mint-based HTTP/1 streaming transport. Connects directly to a caller-validated IP tuple without re-resolving the hostname, while driving the Host header, TLS SNI and certificate hostname verification against the original hostname. Tries the validated addresses in order, with `:connect_timeout` shared as one budget across all attempts. TLS is always `verify: :verify_peer`; any `:verify`/`:verify_fun` in `:transport_opts` is dropped. Exposes `stream_while/4`, which folds upstream events through the reducer `Philter.proxy/2` passes in. Runs the socket in active mode with a `receive` pinned to its own socket, and drains pending messages between request-body chunks so an early upstream response cannot deadlock a large upload. Opens a fresh connection per request; there is no pool.

**`Philter.Handler`**: behaviour for lifecycle callbacks. State threads through `handle_request_started/2` → `handle_response_started/2` → `handle_response_finished/2`. Only `handle_response_finished/2` is required. `handle_request_started/2` can reject before the upstream call, in which case `handle_response_finished/2` is not called. Once past that point, `handle_response_finished/2` is always called, including on egress rejections and transport errors.

**`Philter.Observer`** (internal): one linked process spawned per request. Receives `:req_chunk`/`:resp_chunk`/`:resp_started`/`:finalize` messages. Chunks are fire-and-forget; finalize is synchronous with a 5s timeout. Whether to keep the full request body is decided at spawn from the request content type; for the response it is decided on `:resp_started`, which resets the response observation using the upstream content type.

**`Philter.Observation`** (internal): incremental body observation. Streams SHA256 via `:crypto.hash_init/:hash_update/:hash_final` (lowercase hex), captures the first 64KB as a preview (UTF-8 safe), tracks size, and keeps the full body only when told to and only while it stays under `max_payload_size`.

**`Philter.Config`**: resolves configuration as per-request option, then `:philter` app env, then built-in default. Also holds the content-type matcher, which ignores parameters like `charset` and supports wildcards such as `text/*`. `:finch_name` is still resolved but deprecated and ignored.

**`Philter.Timing`**: builds the per-phase timing map (`connect_us`, `send_us`, `recv_us`) the transport returns when `collect_timing: true`. `queue_us` and `idle_time_us` are always `nil` and `reused_connection?` always `false`, since there is no pool.

**`Philter.BodyStream`** (internal): adapts `Plug.Conn.read_body/2` into a `{:stream, enumerable}` for the transport, reading 64,000-byte chunks and calling an `:on_chunk` callback for the observer.

**`Philter.UTF8`**: UTF-8 safe binary truncation for preview data.

### Request Flow

1. Validate header options (`:headers` cannot be combined with `:extra_headers`/`:strip_headers`; raises `ArgumentError`), resolve config and handler, build the upstream URL and outbound headers
2. `handle_request_started/2`: can reject with `{:reject, status, body, state}`
3. Refuse a missing host or a non-`http(s)` scheme (502), then resolve and validate the upstream host via `Philter.Egress`: a blocked IP returns 403, a DNS timeout 504, nothing resolving 502. These rejections still call `handle_response_finished/2`, with empty observations
4. Spawn the linked Observer process
5. Build the transport request pinned to the validated addresses. The request body is streamed via BodyStream (observer gets the chunks) unless `content-length` is `0`, or there is no `content-length` and the request isn't chunked
6. `Philter.Transport.stream_while/4`: `:status` sets the code, `:headers` filters hop-by-hop headers, calls `handle_response_started/2` and starts a chunked response, `:data` forwards chunks to the client and the observer
7. Finalize the observer, call `handle_response_finished/2`, and on success store the observations in `conn.private`

### Key Design Decisions

- **Egress filtering** is deny-by-default: the upstream host is resolved once and every resolved address validated against internal ranges before connecting, then the transport pins to a validated IP and never re-resolves (closing the DNS-rebinding window) while preserving the hostname for the Host header, TLS SNI and certificate verification. Connection identity (scheme, host, port) is taken from the parsed base `:upstream`, the same value that was validated; only the request path comes from the path-appended URL. `:allowed_hosts` is the escape hatch (still resolved, block check skipped). Blocked resolutions return 403 with a static body and the resolved IP is logged server-side only, never sent to the client.
- **Hop-by-hop headers** (te, transfer-encoding, connection, etc.) are filtered from both request and response. Content-length is also removed from responses (chunked encoding is used).
- **Custom `:headers` option** bypasses all request header filtering: headers are sent as-is, and a `host` entry is only added if the caller didn't supply one. Without `:headers`, `host` is always rewritten to the upstream.
- **Body accumulation** is conditional: only for matching content types under `max_payload_size`. Preview and hash are always captured regardless.
- **Error mapping**: a `Mint.TransportError` with reason `:timeout`, `:connect_timeout` or `{:closed, :timeout}` returns 504 and reaches the handler as `error: {:timeout, reason}`; every other transport error returns 502. Observations are only put in `conn.private` on success.

## Testing

Tests use `ExUnit` with `async: true` throughout and `Bypass` for mocking upstream HTTP servers. Test support code is in `test/support/` (compiled via `elixirc_paths` in test env):

- `Philter.TestHelpers`: `bypass_upstream/0`, `test_handler/0`, `json_response/3`, `text_response/3`
- `Philter.LogCapture`: log capture filtered to the calling process. `ExUnit.CaptureLog` sees every concurrently running test's logs, so it cannot prove nothing was logged under `async: true`; use `capture_own_log/1` for that. This works because Philter logs only from the process calling `proxy/2`.

`test/test_helper.exs` sets `allowed_hosts` (`127.0.0.1`, `localhost`) in app env so loopback Bypass servers pass the egress guard while it stays enabled for the rest of the suite. To test that an address is blocked, use a host that isn't on that list and pass a fake `:resolver` (see `test/philter/egress_integration_test.exs`), which also uses `x509` for the TLS/SNI tests.

# Philter

[![Hex.pm](https://img.shields.io/hexpm/v/philter.svg)](https://hex.pm/packages/philter)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/philter)
[![CI](https://github.com/OpenFn/philter/actions/workflows/ci.yml/badge.svg)](https://github.com/OpenFn/philter/actions/workflows/ci.yml)

Streaming HTTP proxy library for Elixir with O(1) memory body observation and
deny-by-default SSRF egress filtering.

> **Philter** — an alchemical potion or charm; from Greek *philtron* (φίλτρον), "love potion."

## Features

- **Zero buffering**: streams requests and responses without accumulating bodies in memory
- **Body observation**: SHA256 hash, size and a UTF-8 safe preview captured as bytes flow through
- **Egress filtering**: upstreams that resolve to private, loopback or cloud-metadata addresses are blocked by default, with DNS-rebinding protection
- **Plug integration**: use as a Plug or call directly from controllers
- **Lifecycle callbacks**: hook request start, first byte and completion for logging or persistence
- **Configurable**: application-level defaults with per-request overrides
- **Self-contained**: manages its own connections, nothing to add to your supervision tree

## Installation

Add `philter` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:philter, "~> 0.4.0"}
  ]
end
```

Philter talks to upstreams directly over [Mint](https://hex.pm/packages/mint)
and opens a fresh HTTP/1 connection per request. There is no connection pool to
configure or supervise, so installation is just the dependency.

## Quick start

Call it from a controller:

```elixir
def proxy(conn, _params) do
  Philter.proxy(conn, upstream: "https://api.example.com")
end
```

Or forward a route prefix in your router:

```elixir
forward "/api", Philter.ProxyPlug, upstream: "https://api.example.com"
```

Note that Philter refuses upstreams that resolve to private or internal
addresses by default. If your upstream is internal, including `localhost` in
development, add it to `:allowed_hosts` (see
[Egress filtering](#egress-filtering-ssrf-protection) below).

## How a request flows

1. Configuration is resolved (per-request options over application config over defaults) and your handler's `handle_request_started/2` runs, which may reject the request outright.
2. The upstream hostname is resolved and every resolved address is validated against the egress policy. A blocked address returns `403`, a DNS timeout `504`, and an unresolvable host `502`.
3. The request body is streamed upstream in chunks and the response is streamed back to the client, with each chunk passed through an observer that incrementally hashes, sizes and previews it.
4. On completion `handle_response_finished/2` is called (always, even on error) and the observations are stored in `conn.private`.

Upstream connection failures surface as `502 Bad Gateway` and upstream timeouts
as `504 Gateway Timeout`.

## Body observation

Philter captures observations about request and response bodies without
buffering them:

```elixir
conn = Philter.proxy(conn, upstream: "https://api.example.com")

# Access observations from conn.private
req_obs = conn.private[:philter_request_observation]
resp_obs = conn.private[:philter_response_observation]

# Each observation contains:
# - :hash - SHA256 hash of the body
# - :size - Total body size in bytes
# - :preview - First 64KB of the body (UTF-8 safe truncation)
# - :body - Full body (only if under max_payload_size and content-type matches)
```

The hash, size and preview are always captured. The full `:body` is only
accumulated when the content type matches `:persistable_content_types` and the
body stays under `:max_payload_size`.

## Handler callbacks

Implement `Philter.Handler` to hook into the proxy lifecycle:

```elixir
defmodule MyApp.ProxyHandler do
  use Philter.Handler

  @impl true
  def handle_request_started(metadata, state) do
    Logger.info("Proxying #{metadata.method} #{metadata.upstream_url}")
    {:ok, state}
  end

  @impl true
  def handle_response_started(metadata, state) do
    Logger.info("TTFB: #{metadata.time_to_first_byte_us}us")
    {:ok, state}
  end

  @impl true
  def handle_response_finished(result, state) do
    Logger.info("Completed: #{result.status} in #{result.timing.total_us}us")
    # result contains :request_observation and :response_observation
    {:ok, state}
  end
end

# Use it:
Philter.proxy(conn,
  upstream: "https://api.example.com",
  handler: {MyApp.ProxyHandler, %{}}
)
```

`handle_request_started/2` can reject a request before it reaches upstream by
returning `{:reject, status, body, state}`. `handle_response_finished/2` is
always called, even on error; check its `:error` field.

## Configuration

Every option below can be set globally under `config :philter` and overridden
per request. Precedence is: per-request option, then application config, then
the built-in default.

| Option | Default | Description |
|--------|---------|-------------|
| `:receive_timeout` | `15_000` | Response timeout in milliseconds |
| `:connect_timeout` | `5_000` | Milliseconds to bound the connection phase to a validated upstream address |
| `:dns_timeout` | `5_000` | Milliseconds to bound upstream DNS resolution |
| `:max_payload_size` | `1_048_576` | Max body size for full accumulation (1MB) |
| `:persistable_content_types` | JSON/XML/text | Content types eligible for body storage, wildcards like `text/*` supported |
| `:block_private_networks` | `true` | Reject upstreams resolving to private/internal ranges (SSRF egress guard) |
| `:allowed_hosts` | `[]` | Hosts that bypass the egress block check (escape hatch) |
| `:log_level` | `:debug` | Logger level for lifecycle events, or `false` to disable |
| `:transport_opts` | `[]` | Extra Mint transport options, e.g. a custom CA bundle. Cannot disable TLS verification |

Set application-wide defaults, including the egress policy:

```elixir
# config/config.exs
config :philter,
  receive_timeout: 30_000,
  max_payload_size: 5_242_880,
  persistable_content_types: ["application/json", "text/*"],
  block_private_networks: true,
  allowed_hosts: ["api.internal"],
  dns_timeout: 2_000
```

Or override per request:

```elixir
Philter.proxy(conn,
  upstream: "https://api.example.com",
  receive_timeout: 60_000,
  max_payload_size: 5_242_880
)
```

Some options only make sense per call and are passed directly to
`Philter.proxy/2` or `Philter.ProxyPlug`: `:upstream` (required), `:path`,
`:handler`, `:headers`, `:extra_headers`, `:strip_headers` and
`:collect_timing`. See the `Philter.proxy/2` docs for the full list.

## Egress filtering (SSRF protection)

Philter is often placed in front of caller-supplied upstream URLs, which makes
Server-Side Request Forgery (SSRF) a real risk: a malicious caller could point
the proxy at internal services or a cloud metadata endpoint. Philter defends
against this **by default**.

- **Deny-by-default.** With `block_private_networks: true` (the default),
  Philter rejects any upstream whose hostname resolves to a private, loopback,
  link-local, CGNAT or otherwise internal address. This covers RFC1918
  (`10/8`, `172.16/12`, `192.168/16`), loopback (`127/8`, `::1`), link-local
  including the cloud metadata address `169.254.169.254` (IMDS), IPv6 unique
  local (`fc00::/7`) and link-local (`fe80::/10`), and reserved ranges. IPv6
  forms that embed an IPv4 address (IPv4-mapped, IPv4-compatible, NAT64, 6to4,
  Teredo) are unwrapped and re-checked. See `Philter.Egress` for the full list.
- **Blocking is on the resolved IP, not the URL.** Because Philter validates the
  addresses the hostname actually resolves to, octal/hex/decimal IP-encoding
  tricks in the URL do not help an attacker.
- **Resolve-and-pin (DNS-rebinding protection).** Philter resolves the hostname
  once, validates every answer, and connects the socket to a validated IP
  without ever re-resolving, while still using the original hostname for the
  Host header, TLS SNI and certificate verification. A name that resolves
  "clean" then flips to an internal IP cannot slip through.
- **Only `http` and `https` upstreams are accepted.** Any other scheme is
  refused with `502`.
- **What a rejection looks like.** A blocked address returns `403` with a static
  body (`Request blocked by egress policy`); the resolved IP is logged
  server-side only and never returned to the client. A DNS timeout returns
  `504`; an unresolvable host returns `502`.

### Reaching an internal host on purpose

If you genuinely need to proxy to an internal upstream, add its hostname to
`allowed_hosts`. Listed hosts bypass the egress check entirely (matched
case-insensitively, ignoring a trailing dot):

```elixir
Philter.proxy(conn,
  upstream: "http://api.internal:4000",
  allowed_hosts: ["api.internal"]
)
```

For an allowance that applies everywhere, set it in application config instead:

```elixir
# config/dev.exs
config :philter, allowed_hosts: ["localhost"]
```

### Residual risk

Egress filtering blocks *internal* targets; it does **not** stop Philter being
used as a relay to *public* hosts. An operator exposing Philter to untrusted
callers can still be abused for reconnaissance or to launder attacks against
third parties, which could get the deploying server's IP flagged or blocklisted.
Deny-by-default does not prevent this. Rate limiting, authentication and
attribution are the operator's responsibility and are out of scope for Philter.

## Documentation

Full documentation: [https://hexdocs.pm/philter](https://hexdocs.pm/philter)

## License

Apache-2.0

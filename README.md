# Philter

[![Hex.pm](https://img.shields.io/hexpm/v/philter.svg)](https://hex.pm/packages/philter)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/philter)
[![CI](https://github.com/OpenFn/philter/actions/workflows/ci.yml/badge.svg)](https://github.com/OpenFn/philter/actions/workflows/ci.yml)

Streaming HTTP proxy library with O(1) memory body observation for Elixir.

> **Philter** — an alchemical potion or charm; from Greek *philtron* (φίλτρον), "love potion."

## Features

- **Zero buffering**: Stream requests and responses without memory accumulation
- **Body observation**: Capture SHA256, size, preview, timing without buffering
- **SSRF egress filtering**: Deny-by-default blocking of private, loopback and cloud-metadata targets, with DNS-rebinding protection
- **Plug integration**: Use as Plug or call directly from controllers
- **Configurable**: Per-request overrides for all settings
- **Observable**: Lifecycle callbacks for monitoring and logging

## Installation

Add `philter` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:philter, "~> 0.4.0"}
  ]
end
```

Philter uses a Mint-direct transport and manages its own connections, so there
is no Finch pool to add to your supervision tree.

## Quick Start

Use in your controller:

```elixir
def proxy(conn, _params) do
  Philter.proxy(conn, upstream: "https://api.example.com")
end
```

Or as a Plug in your router:

```elixir
forward "/api", Philter.ProxyPlug, upstream: "https://api.example.com"
```

## Body Observation

Philter captures observations about request and response bodies without buffering:

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

## Handler Callbacks

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

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `:receive_timeout` | `15_000` | Response timeout in milliseconds |
| `:max_payload_size` | `1_048_576` | Max body size for full accumulation (1MB) |
| `:persistable_content_types` | JSON/XML/text | Content types eligible for body storage |
| `:block_private_networks` | `true` | Reject upstreams resolving to private/internal ranges (SSRF egress guard) |
| `:allowed_hosts` | `[]` | Hosts that bypass the egress block check (escape hatch) |
| `:dns_timeout` | `5_000` | Milliseconds to bound upstream DNS resolution |
| `:finch_name` | — | **Deprecated and ignored** — the transport no longer uses Finch |

Override per-request:

```elixir
Philter.proxy(conn,
  upstream: "https://api.example.com",
  receive_timeout: 60_000,
  max_payload_size: 5_242_880
)
```

Or set application defaults:

```elixir
# config/config.exs
config :philter,
  receive_timeout: 30_000,
  max_payload_size: 5_242_880,
  persistable_content_types: ["application/json", "text/*"]
```

## Security / SSRF egress filtering

Philter is often placed in front of caller-supplied upstream URLs, which makes
Server-Side Request Forgery (SSRF) a real risk: a malicious caller could point
the proxy at internal services or a cloud metadata endpoint. Philter defends
against this **by default**.

- **Deny-by-default.** With `block_private_networks: true` (the default),
  Philter rejects any upstream whose hostname resolves to a private, loopback,
  link-local, CGNAT or otherwise internal address. This covers RFC1918
  (`10/8`, `172.16/12`, `192.168/16`), loopback (`127/8`, `::1`), link-local
  including the cloud metadata address `169.254.169.254` (IMDS), IPv6 unique
  local (`fc00::/7`) and link-local (`fe80::/10`), and reserved ranges — plus
  IPv4-mapped and NAT64 IPv6 forms, which are unwrapped and re-checked. See
  `Philter.Egress` for the full list.
- **Blocking is on the resolved IP, not the URL.** Because Philter validates the
  addresses the hostname actually resolves to, octal/hex/decimal IP-encoding
  tricks in the URL do not help an attacker.
- **Resolve-and-pin (DNS-rebinding protection).** Philter resolves the hostname
  once, validates every answer, and connects the socket to a validated IP
  without ever re-resolving — while still using the original hostname for the
  Host header, TLS SNI and certificate verification. A name that resolves
  "clean" then flips to an internal IP cannot slip through.
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

### Residual risk

Egress filtering blocks *internal* targets; it does **not** stop Philter being
used as a relay to *public* hosts. An operator exposing Philter to untrusted
callers can still be abused for reconnaissance or to launder attacks against
third parties, which could get the deploying server's IP flagged or blocklisted.
Deny-by-default does not prevent this — rate-limiting, authentication and
attribution are the operator's responsibility and are out of scope for Philter.

## Documentation

Full documentation: [https://hexdocs.pm/philter](https://hexdocs.pm/philter)

## License

Apache-2.0

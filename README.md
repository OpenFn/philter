# Philter

[![Hex.pm](https://img.shields.io/hexpm/v/philter.svg)](https://hex.pm/packages/philter)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/philter)
[![CI](https://github.com/OpenFn/philter/actions/workflows/ci.yml/badge.svg)](https://github.com/OpenFn/philter/actions/workflows/ci.yml)

Streaming HTTP proxy library with O(1) memory body observation for Elixir.

> **Philter** — an alchemical potion or charm; from Greek *philtron* (φίλτρον), "love potion."

## Features

- **Zero buffering**: Stream requests and responses without memory accumulation
- **Body observation**: Capture SHA256, size, preview, timing without buffering
- **Plug integration**: Use as Plug or call directly from controllers
- **Configurable**: Per-request overrides for all settings
- **Observable**: Lifecycle callbacks for monitoring and logging

## Installation

Add `philter` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:philter, "~> 0.1.0"}
  ]
end
```

## Quick Start

1. Add Finch to your supervision tree:

```elixir
children = [
  {Finch, name: MyApp.Finch}
]
```

2. Configure Philter:

```elixir
# config/config.exs
config :philter, finch_name: MyApp.Finch
```

3. Use in your controller:

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
| `:finch_name` | `Philter.Finch` | Name of the Finch pool to use |
| `:receive_timeout` | `15_000` | Response timeout in milliseconds |
| `:max_payload_size` | `1_048_576` | Max body size for full accumulation (1MB) |
| `:persistable_content_types` | JSON/XML/text | Content types eligible for body storage |

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
  finch_name: MyApp.Finch,
  receive_timeout: 30_000,
  max_payload_size: 5_242_880,
  persistable_content_types: ["application/json", "text/*"]
```

## Documentation

Full documentation: [https://hexdocs.pm/philter](https://hexdocs.pm/philter)

## License

Apache-2.0

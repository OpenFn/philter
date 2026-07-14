defmodule Philter do
  @moduledoc """
  Streaming HTTP proxy with request/response observation.

  Philter forwards HTTP requests to upstream servers while capturing body observations
  (hash, size, timing, preview) without buffering. Supports conditional body
  accumulation for content types you want to persist.

  > **Philter** — an alchemical potion or charm; from Greek *philtron* (φίλτρον), "love potion."
  > Here it evokes both *filtering* (the proxy inspects and forwards HTTP traffic)
  > and the Elixir ecosystem's alchemical tradition.

  ## HTTP Client

  Philter uses a Mint-direct transport that resolves the upstream hostname,
  validates the resolved addresses against the SSRF egress policy (see
  `Philter.Egress`), and pins the connection to a validated IP. No Finch pool is
  needed; the `:finch_name` option is deprecated and ignored.

  ## Quick Start

      # In a Phoenix controller
      def proxy(conn, _params) do
        Philter.proxy(conn, upstream: "http://api.example.com")
      end

      # Or as a Plug in your router
      forward "/api", Philter.ProxyPlug, upstream: "http://api.example.com"

  ## Configuration

  Set defaults in your config and override per-request. See `Philter.Config` for details.

      # config/config.exs
      config :philter,
        receive_timeout: 30_000,
        max_payload_size: 5_242_880

  ## Handler Callbacks

  Implement `Philter.Handler` to hook into the proxy lifecycle:

    * `handle_request_started/2` - Called before sending to upstream
    * `handle_response_started/2` - Called on first byte received (TTFB)
    * `handle_response_finished/2` - Called when complete, with body observations

  Example:

      defmodule MyHandler do
        use Philter.Handler

        @impl true
        def handle_response_finished(result, state) do
          # result contains :request_observation and :response_observation
          # each with :hash, :size, :body, :preview
          {:ok, state}
        end
      end

  """

  import Plug.Conn
  require Logger

  alias Philter.{Config, Egress, Observation, Observer, Transport}

  @timeout_reasons [:timeout, :connect_timeout, {:closed, :timeout}]

  @hop_by_hop_headers [
    "te",
    "transfer-encoding",
    "trailer",
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "upgrade"
  ]

  @type proxy_opts :: [
          upstream: String.t(),
          path: String.t() | (Plug.Conn.t() -> String.t()),
          handler: module() | {module(), term()},
          headers: [{String.t(), String.t()}],
          extra_headers: [{String.t(), String.t()}],
          strip_headers: [String.t()],
          finch_name: atom(),
          receive_timeout: pos_integer(),
          max_payload_size: pos_integer(),
          persistable_content_types: [String.t()],
          log_level: Logger.level() | false,
          collect_timing: boolean(),
          block_private_networks: boolean(),
          allowed_hosts: [String.t()],
          dns_timeout: pos_integer(),
          connect_timeout: pos_integer(),
          transport_opts: keyword()
        ]

  @doc """
  Proxies an HTTP request to an upstream server.

  Streams the request to upstream and the response back to the client. Call this
  after authentication or other pre-processing (unlike `Philter.ProxyPlug`).

  ## Examples

      # Basic proxy
      Philter.proxy(conn, upstream: "http://api.example.com")

      # With handler for logging/persistence
      Philter.proxy(conn,
        upstream: "http://api.example.com",
        handler: {MyHandler, %{user_id: user.id}}
      )

      # Override timeout for slow endpoints
      Philter.proxy(conn,
        upstream: "http://api.example.com",
        receive_timeout: 60_000
      )

  ## Options

    * `:upstream` - Base URL of the upstream server. **Required.**

    * `:handler` - Handler module or `{module, state}` tuple for lifecycle
      callbacks. See `Philter.Handler` for the callback interface.

    * `:headers` - Pre-assembled outbound request headers as `[{name, value}]`
      tuples. When provided, these replace `conn.req_headers` (no hop-by-hop
      filtering) and an explicit `"host"` entry (case-insensitive) is preserved
      as-is; if no `"host"` is included, the upstream host is appended as a
      default.
      When omitted, `conn.req_headers` are filtered (hop-by-hop removed, keys
      lowercased) and the `host` header is always rewritten to match upstream.
      Cannot be combined with `:extra_headers` or `:strip_headers`.

    * `:extra_headers` - Additional `[{name, value}]` headers to merge into
      the outbound request. Applied after hop-by-hop filtering and host
      rewriting. If an extra header matches an existing header name
      (case-insensitive), the existing header is replaced. Cannot be combined
      with `:headers`.

    * `:strip_headers` - List of header names (case-insensitive) to remove
      from the outbound request. Applied after hop-by-hop filtering and host
      rewriting but before `:extra_headers`. Cannot be combined with `:headers`.

      When both `:strip_headers` and `:extra_headers` are used, the processing
      order is: filter hop-by-hop headers → rewrite host → strip → merge extra.

    * `:finch_name` - **Deprecated and ignored.** The transport uses no
      connection pool. Accepted so existing callers do not crash.

    * `:receive_timeout` - Response timeout in milliseconds. Default: `15_000`.

    * `:max_payload_size` - Max body size in bytes for full accumulation.
      Bodies exceeding this are still hashed and previewed. Default: `1_048_576` (1MB).

    * `:path` - Override the request path sent to upstream. Can be a string
      or a function `(Plug.Conn.t() -> String.t())`. Default: `conn.request_path`.

    * `:persistable_content_types` - Content types eligible for body accumulation.
      Supports wildcards like `"text/*"`. Default: JSON, XML, and text types.

    * `:log_level` - Logger level for lifecycle events (`:debug`, `:info`, etc.)
      or `false` to disable all logging. Default: `:debug`.

    * `:collect_timing` - When `true`, captures a per-phase timing breakdown
      (`connect_us`, `send_us`, `recv_us`) measured directly around the Mint
      transport calls. `queue_us` and `idle_time_us` are always `nil` and
      `reused_connection?` is always `false` (no connection pool). Phase fields
      in `timing` are `nil` when disabled. Default: `false`.

    * `:block_private_networks` - When `true` (default), reject upstreams whose
      hostname resolves to a private, loopback, link-local or otherwise internal
      address (SSRF egress guard). See `Philter.Egress`.

    * `:allowed_hosts` - Hosts that bypass the egress block check entirely (the
      escape hatch, e.g. a deliberately internal upstream). Exact match after
      downcase and trailing-dot strip. Default: `[]`.

    * `:dns_timeout` - Milliseconds to bound upstream DNS resolution. On timeout
      the request fails with `504`. Default: `5_000`.

    * `:connect_timeout` - Milliseconds to bound the connection phase to a
      validated upstream address. Default: `5_000`.

    * `:transport_opts` - Extra Mint transport options merged into the
      connection (e.g. `cacertfile:` to trust a custom CA bundle). Cannot be
      used to disable TLS certificate verification. Default: `[]`.

  ## Return Value

  Returns the `conn` with response sent. Observations are stored in:

    * `conn.private[:philter_request_observation]` - Request body observation
    * `conn.private[:philter_response_observation]` - Response body observation

  Each observation contains `:hash`, `:size`, `:body` (if accumulated), and `:preview`.

  ## Error Handling

  On upstream errors, returns `502 Bad Gateway`. On timeouts, returns `504 Gateway Timeout`.
  The handler's `handle_response_finished/2` is still called with the `:error` field set.
  """
  @spec proxy(Plug.Conn.t(), proxy_opts()) :: Plug.Conn.t()
  def proxy(conn, opts) do
    validate_header_opts!(opts)
    upstream = Keyword.fetch!(opts, :upstream)
    upstream_uri = URI.parse(upstream)
    config = Config.resolve(opts)
    handler = resolve_handler(opts)

    started_at = System.monotonic_time(:microsecond)
    path = resolve_path(opts, conn)
    upstream_url = build_upstream_url(upstream, path, conn.query_string)
    req_content_type = get_content_type(conn.req_headers)
    strip_headers = Keyword.get(opts, :strip_headers, [])
    extra_headers = Keyword.get(opts, :extra_headers, [])

    outbound_headers =
      build_outbound_headers(
        Keyword.get(opts, :headers),
        conn,
        upstream,
        strip_headers,
        extra_headers
      )

    log_level = config.log_level
    maybe_warn_finch_name(opts, log_level)

    # Log #1: Request start
    log(log_level, fn ->
      [
        "Philter ",
        conn.method,
        " ",
        upstream_url,
        " host=",
        extract_host(upstream)
      ]
    end)

    # Notify handler of request start
    case notify_request_started(handler, %{
           upstream_url: upstream_url,
           method: conn.method,
           headers: outbound_headers,
           content_type: req_content_type,
           started_at: started_at
         }) do
      {:ok, handler_state} ->
        ctx = %{
          conn: conn,
          opts: opts,
          config: config,
          handler: handler,
          handler_state: handler_state,
          upstream_url: upstream_url,
          outbound_headers: outbound_headers,
          req_content_type: req_content_type,
          started_at: started_at,
          log_level: log_level,
          upstream: upstream,
          upstream_uri: upstream_uri
        }

        with :ok <- validate_upstream(upstream_uri),
             {:ok, addresses} <-
               Egress.resolve_and_validate(upstream_uri.host, egress_opts(config, opts)) do
          stream_upstream(ctx, addresses)
        else
          {:error, reason} -> egress_reject(ctx, reason)
        end

      {:reject, status, body, _handler_state} ->
        # Log #5: Handler rejection
        log(log_level, fn ->
          [
            "Philter rejected ",
            conn.method,
            " ",
            upstream_url,
            " status=",
            Integer.to_string(status)
          ]
        end)

        conn |> send_resp(status, body) |> halt()
    end
  end

  # Stream message handlers (replaces ResponseStreamer)

  defp handle_stream_message({:status, status}, acc) do
    # Log #2: Status from upstream
    log(acc.log_level, fn -> ["Philter ", Integer.to_string(status), " from upstream"] end)
    {:cont, %{acc | status: status}}
  end

  defp handle_stream_message({:headers, headers}, acc) do
    filtered = filter_response_headers(headers)
    content_type = get_content_type(headers)

    # Observer reconfigures response accumulation
    Observer.response_started(acc.observer, headers)

    # Handler callback (synchronous, in caller process)
    acc = notify_handler_response_started(acc, headers, content_type)

    conn =
      acc.conn
      |> apply_resp_headers(filtered)
      |> send_chunked(acc.status)

    {:cont, %{acc | conn: conn}}
  end

  defp handle_stream_message({:data, chunk}, acc) do
    Observer.response_chunk(acc.observer, chunk)

    case chunk(acc.conn, chunk) do
      {:ok, conn} -> {:cont, %{acc | conn: conn}}
      {:error, reason} -> {:halt, %{acc | error: reason}}
    end
  end

  defp handle_stream_message({:trailers, _}, acc), do: {:cont, acc}

  # Handler response_started notification

  defp notify_handler_response_started(%{handler: nil} = acc, _headers, _ct),
    do: acc

  defp notify_handler_response_started(acc, headers, content_type) do
    {module, handler_state} = acc.handler

    if function_exported?(module, :handle_response_started, 2) do
      ttfb = System.monotonic_time(:microsecond) - acc.started_at

      {:ok, new_state} =
        module.handle_response_started(
          %{
            status: acc.status,
            headers: headers,
            content_type: content_type,
            time_to_first_byte_us: ttfb
          },
          handler_state
        )

      %{acc | handler: {module, new_state}}
    else
      acc
    end
  end

  # Private functions

  defp validate_header_opts!(opts) do
    if Keyword.has_key?(opts, :headers) and
         (Keyword.has_key?(opts, :extra_headers) or Keyword.has_key?(opts, :strip_headers)) do
      raise ArgumentError,
            ":headers cannot be combined with :extra_headers or :strip_headers"
    end
  end

  defp maybe_warn_finch_name(_opts, false), do: :ok

  defp maybe_warn_finch_name(opts, _log_level) do
    if Keyword.has_key?(opts, :finch_name) or Application.get_env(:philter, :finch_name) != nil do
      Logger.warning(
        "Philter :finch_name is deprecated and ignored; the Mint transport uses no connection pool"
      )
    end

    :ok
  end

  defp resolve_handler(opts) do
    case Keyword.get(opts, :handler) do
      nil ->
        nil

      {module, args} when is_atom(module) ->
        Code.ensure_loaded!(module)
        {module, args}

      module when is_atom(module) ->
        Code.ensure_loaded!(module)
        {module, []}
    end
  end

  defp build_outbound_headers(nil, conn, upstream, strip_headers, extra_headers) do
    strip_names = MapSet.new(strip_headers, &String.downcase/1)
    extra_names = MapSet.new(extra_headers, fn {k, _} -> String.downcase(k) end)
    remove_names = MapSet.union(strip_names, extra_names)

    conn.req_headers
    |> filter_request_headers()
    |> put_host_header(extract_host(upstream))
    |> Enum.reject(fn {k, _} -> k in remove_names end)
    |> Kernel.++(extra_headers)
  end

  defp build_outbound_headers(headers, _conn, upstream, _strip_headers, _extra_headers) do
    maybe_put_host_header(headers, extract_host(upstream))
  end

  defp put_host_header(headers, host) do
    Enum.reject(headers, &host_header?/1) ++ [{"host", host}]
  end

  defp maybe_put_host_header(headers, host) do
    if Enum.any?(headers, &host_header?/1), do: headers, else: headers ++ [{"host", host}]
  end

  defp host_header?({k, _}), do: String.downcase(k) == "host"

  defp extract_host(url) do
    uri = URI.parse(url)
    host = uri.host || ""

    case uri.port do
      nil -> host
      80 -> host
      443 -> host
      port -> "#{host}:#{port}"
    end
  end

  defp resolve_path(opts, conn) do
    case Keyword.get(opts, :path) do
      nil -> conn.request_path
      fun when is_function(fun, 1) -> fun.(conn)
      path when is_binary(path) -> path
    end
  end

  defp build_upstream_url(upstream, path, query_string) do
    query = if query_string == "", do: "", else: "?#{query_string}"
    "#{upstream}#{path}#{query}"
  end

  defp get_content_type(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp build_request_body(conn, observer) do
    case get_req_header(conn, "content-length") do
      ["0"] ->
        {:stream, []}

      [] ->
        case get_req_header(conn, "transfer-encoding") do
          ["chunked"] ->
            Philter.BodyStream.from_conn(conn,
              on_chunk: fn chunk ->
                Observer.request_chunk(observer, chunk)
              end
            )

          _ ->
            {:stream, []}
        end

      _ ->
        Philter.BodyStream.from_conn(conn,
          on_chunk: fn chunk ->
            Observer.request_chunk(observer, chunk)
          end
        )
    end
  end

  defp filter_request_headers(headers) do
    headers
    |> Enum.reject(fn {key, _} ->
      String.downcase(key) in @hop_by_hop_headers
    end)
    |> Enum.map(fn {key, value} -> {String.downcase(key), value} end)
  end

  defp filter_response_headers(headers) do
    headers
    |> Enum.reject(fn {key, _} ->
      key = String.downcase(key)
      key in @hop_by_hop_headers or key == "content-length"
    end)
    |> Enum.map(fn {key, value} -> {String.downcase(key), value} end)
  end

  defp apply_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      put_resp_header(conn, String.downcase(key), value)
    end)
  end

  defp handler_state(%{handler: {_, state}}), do: state
  defp handler_state(_), do: nil

  defp handle_error(acc, handler, info) do
    # Log #4: Error
    if acc.log_level do
      Logger.error(fn ->
        [
          "Philter error ",
          Integer.to_string(info.status),
          " ",
          inspect(info.error),
          " upstream=",
          info.upstream_url
        ]
      end)
    end

    observations = Observer.finalize(acc.observer)
    duration_us = System.monotonic_time(:microsecond) - info.started_at
    handler_state = handler_state(acc)

    notify_response_finished(
      handler,
      %{
        request_observation: observations.request,
        response_observation: observations.response,
        error: info.error,
        upstream_url: info.upstream_url,
        method: info.method,
        status: nil,
        timing: build_timing(duration_us, info.timing)
      },
      handler_state
    )

    acc.conn |> send_resp(info.status, info.body) |> halt()
  end

  # Egress gate: resolve + validate the upstream, then stream via the Mint
  # transport pinned to a validated address.

  defp egress_opts(config, opts) do
    base = [
      block_private_networks: config.block_private_networks,
      allowed_hosts: config.allowed_hosts,
      dns_timeout: config.dns_timeout
    ]

    case Keyword.get(opts, :resolver) do
      nil -> base
      resolver -> Keyword.put(base, :resolver, resolver)
    end
  end

  defp egress_reject(ctx, reason) do
    {status, body} = egress_response(reason)
    log_egress_rejection(reason, status, ctx.upstream_url, ctx.log_level)

    duration_us = System.monotonic_time(:microsecond) - ctx.started_at
    observation = empty_observation()

    notify_response_finished(
      ctx.handler,
      %{
        request_observation: observation,
        response_observation: observation,
        error: reason,
        upstream_url: ctx.upstream_url,
        method: ctx.conn.method,
        status: nil,
        timing: build_timing(duration_us, nil)
      },
      ctx.handler_state
    )

    ctx.conn |> send_resp(status, body) |> halt()
  end

  # A missing/blank host or a non-http(s) scheme can never yield a safe upstream
  # connection, so both are refused as a gateway error before the egress gate runs.
  defp validate_upstream(%URI{host: host}) when host in [nil, ""], do: {:error, :invalid_host}

  defp validate_upstream(%URI{scheme: scheme}) when scheme not in ["http", "https"],
    do: {:error, :unsupported_scheme}

  defp validate_upstream(_uri), do: :ok

  defp egress_response({:blocked, _ip}), do: {403, "Request blocked by egress policy"}
  defp egress_response(:dns_timeout), do: {504, "Gateway Timeout"}

  defp egress_response(reason) when reason in [:no_addresses, :invalid_host, :unsupported_scheme],
    do: {502, "Bad Gateway"}

  # Bodies are never observed on a reject, so both observations are empty.
  defp empty_observation, do: Observation.finalize(Observation.new())

  # The resolved IP is logged server-side only; it must never reach the client
  # (avoids confirming internal topology).
  defp log_egress_rejection(_reason, _status, _upstream_url, false), do: :ok

  defp log_egress_rejection({:blocked, ip}, status, upstream_url, _level) do
    Logger.error(fn ->
      [
        "Philter egress blocked ",
        Integer.to_string(status),
        " upstream=",
        upstream_url,
        " resolved=",
        :inet.ntoa(ip) |> to_string()
      ]
    end)
  end

  defp log_egress_rejection(reason, status, upstream_url, _level) do
    Logger.error(fn ->
      [
        "Philter egress error ",
        Integer.to_string(status),
        " ",
        inspect(reason),
        " upstream=",
        upstream_url
      ]
    end)
  end

  defp stream_upstream(ctx, addresses) do
    %{
      conn: conn,
      config: config,
      handler: handler,
      handler_state: handler_state,
      upstream_url: upstream_url,
      outbound_headers: outbound_headers,
      started_at: started_at,
      log_level: log_level
    } = ctx

    req_accumulate? =
      Config.content_type_persistable?(ctx.req_content_type, config.persistable_content_types)

    {:ok, observer} = Observer.start_link(config: config, req_accumulate?: req_accumulate?)
    request_body = build_request_body(conn, observer)

    # Connection identity (scheme/host/port) comes from the base upstream — the
    # same parse that was validated — so the pinned/SNI host can never diverge
    # from the validated one. Only the request-line target is taken from the
    # path-appended URL.
    identity = ctx.upstream_uri

    request = %{
      scheme: scheme_atom(identity.scheme),
      host: identity.host,
      addresses: addresses,
      port: identity.port,
      method: String.upcase(conn.method),
      path: request_target(URI.parse(upstream_url)),
      headers: outbound_headers,
      body: request_body
    }

    acc = %{
      conn: conn,
      handler: if(handler, do: {elem(handler, 0), handler_state}, else: nil),
      observer: observer,
      status: nil,
      started_at: started_at,
      error: nil,
      log_level: log_level,
      upstream_url: upstream_url
    }

    {result, timing} =
      Transport.stream_while(request, acc, &handle_stream_message/2,
        receive_timeout: config.receive_timeout,
        connect_timeout: config.connect_timeout,
        transport_opts: config.transport_opts,
        collect_timing: Keyword.get(ctx.opts, :collect_timing, false)
      )

    finish_stream(result, timing, ctx, observer)
  end

  defp finish_stream({:ok, acc}, timing, ctx, observer) do
    %{handler: handler, upstream_url: upstream_url, started_at: started_at, log_level: log_level} =
      ctx

    observations = Observer.finalize(observer)
    duration_us = System.monotonic_time(:microsecond) - started_at

    log(log_level, fn ->
      [
        "Philter complete ",
        Integer.to_string(acc.status),
        " ",
        Integer.to_string(observations.response.size),
        "B ",
        Integer.to_string(div(duration_us, 1000)),
        "ms"
      ]
    end)

    notify_response_finished(
      handler,
      %{
        request_observation: observations.request,
        response_observation: observations.response,
        error: nil,
        upstream_url: upstream_url,
        method: acc.conn.method,
        status: acc.conn.status,
        timing: build_timing(duration_us, timing)
      },
      handler_state(acc)
    )

    acc.conn
    |> put_private(:philter_request_observation, observations.request)
    |> put_private(:philter_response_observation, observations.response)
  end

  defp finish_stream({:error, %Mint.TransportError{reason: reason}, acc}, timing, ctx, _observer)
       when reason in @timeout_reasons do
    handle_error(acc, ctx.handler, %{
      upstream_url: ctx.upstream_url,
      method: ctx.conn.method,
      started_at: ctx.started_at,
      error: {:timeout, reason},
      status: 504,
      body: "Gateway Timeout",
      timing: timing
    })
  end

  defp finish_stream({:error, error, acc}, timing, ctx, _observer) do
    handle_error(acc, ctx.handler, %{
      upstream_url: ctx.upstream_url,
      method: ctx.conn.method,
      started_at: ctx.started_at,
      error: error,
      status: 502,
      body: "Bad Gateway",
      timing: timing
    })
  end

  defp scheme_atom("https"), do: :https
  defp scheme_atom("http"), do: :http

  defp request_target(%URI{path: path, query: query}) do
    (path || "/") <> if query, do: "?" <> query, else: ""
  end

  defp build_timing(total_us, nil) do
    %{
      total_us: total_us,
      queue_us: nil,
      connect_us: nil,
      send_us: nil,
      recv_us: nil,
      idle_time_us: nil,
      reused_connection?: nil
    }
  end

  defp build_timing(total_us, phase_timing) do
    Map.put(phase_timing, :total_us, total_us)
  end

  defp notify_request_started(nil, _metadata), do: {:ok, nil}

  defp notify_request_started({module, args}, metadata) do
    if function_exported?(module, :handle_request_started, 2) do
      module.handle_request_started(metadata, args)
    else
      {:ok, args}
    end
  end

  defp notify_response_finished(nil, _result, _state), do: {:ok, nil}

  defp notify_response_finished({module, _args}, result, state) do
    module.handle_response_finished(result, state)
  end

  defp log(false, _fun), do: :ok
  defp log(level, fun), do: Logger.log(level, fun)
end

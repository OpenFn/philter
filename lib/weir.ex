defmodule Weir do
  @moduledoc """
  Streaming HTTP proxy with request/response observation.

  Weir forwards HTTP requests to upstream servers while capturing body observations
  (hash, size, timing, preview) without buffering. Supports conditional body
  accumulation for content types you want to persist.

  > **Weir** /wɪər/ - A low dam built across a river to raise the level of water
  > upstream or regulate its flow, often used for measuring flow rate. Perfect
  > metaphor for a streaming proxy that observes traffic without blocking it.

  ## Finch Setup (Required)

  Weir requires a running Finch HTTP client instance. Add to your application's
  supervision tree:

      # lib/my_app/application.ex
      children = [
        {Finch, name: MyApp.Finch}
      ]

  Then configure Weir to use it:

      # config/config.exs
      config :weir, finch_name: MyApp.Finch

  Or pass it per-request:

      Weir.proxy(conn, upstream: "https://api.example.com", finch_name: MyApp.Finch)

  ## Quick Start

      # In a Phoenix controller
      def proxy(conn, _params) do
        Weir.proxy(conn, upstream: "http://api.example.com")
      end

      # Or as a Plug in your router
      forward "/api", Weir.ProxyPlug, upstream: "http://api.example.com"

  ## Configuration

  Set defaults in your config and override per-request. See `Weir.Config` for details.

      # config/config.exs
      config :weir,
        finch_name: MyApp.Finch,
        receive_timeout: 30_000,
        max_payload_size: 5_242_880

  ## Handler Callbacks

  Implement `Weir.Handler` to hook into the proxy lifecycle:

    * `handle_request_started/2` - Called before sending to upstream
    * `handle_response_started/2` - Called on first byte received (TTFB)
    * `handle_response_finished/2` - Called when complete, with body observations

  Example:

      defmodule MyHandler do
        use Weir.Handler

        @impl true
        def handle_response_finished(result, state) do
          # result contains :request_observation and :response_observation
          # each with :hash, :size, :body, :preview, :duration_us
          {:ok, state}
        end
      end

  """

  import Plug.Conn
  require Logger

  alias Weir.{Config, Observer}

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
          finch_name: atom(),
          receive_timeout: pos_integer(),
          max_payload_size: pos_integer(),
          persistable_content_types: [String.t()]
        ]

  @doc """
  Proxies an HTTP request to an upstream server.

  Streams the request to upstream and the response back to the client. Call this
  after authentication or other pre-processing (unlike `Weir.ProxyPlug`).

  ## Examples

      # Basic proxy
      Weir.proxy(conn, upstream: "http://api.example.com")

      # With handler for logging/persistence
      Weir.proxy(conn,
        upstream: "http://api.example.com",
        handler: {MyHandler, %{user_id: user.id}}
      )

      # Override timeout for slow endpoints
      Weir.proxy(conn,
        upstream: "http://api.example.com",
        receive_timeout: 60_000
      )

  ## Options

    * `:upstream` - Base URL of the upstream server. **Required.**

    * `:handler` - Handler module or `{module, state}` tuple for lifecycle
      callbacks. See `Weir.Handler` for the callback interface.

    * `:headers` - Pre-assembled outbound request headers as `[{name, value}]`
      tuples. When provided, these headers are sent as-is to the upstream
      (no filtering of `conn.req_headers`, no hop-by-hop removal). When omitted,
      `conn.req_headers` are filtered (hop-by-hop removed, keys lowercased).

    * `:finch_name` - Finch pool name. Default: configured value (see `Weir.Config`).

    * `:receive_timeout` - Response timeout in milliseconds. Default: `15_000`.

    * `:max_payload_size` - Max body size in bytes for full accumulation.
      Bodies exceeding this are still hashed and previewed. Default: `1_048_576` (1MB).

    * `:path` - Override the request path sent to upstream. Can be a string
      or a function `(Plug.Conn.t() -> String.t())`. Default: `conn.request_path`.

    * `:persistable_content_types` - Content types eligible for body accumulation.
      Supports wildcards like `"text/*"`. Default: JSON, XML, and text types.

  ## Return Value

  Returns the `conn` with response sent. Observations are stored in:

    * `conn.private[:weir_request_observation]` - Request body observation
    * `conn.private[:weir_response_observation]` - Response body observation

  Each observation contains `:hash`, `:size`, `:body` (if accumulated), `:preview`,
  and `:duration_us`.

  ## Error Handling

  On upstream errors, returns `502 Bad Gateway`. On timeouts, returns `504 Gateway Timeout`.
  The handler's `handle_response_finished/2` is still called with the `:error` field set.
  """
  @spec proxy(Plug.Conn.t(), proxy_opts()) :: Plug.Conn.t()
  def proxy(conn, opts) do
    upstream = Keyword.fetch!(opts, :upstream)
    config = Config.resolve(opts)
    handler = resolve_handler(opts)

    started_at = System.monotonic_time(:microsecond)
    path = resolve_path(opts, conn)
    upstream_url = build_upstream_url(upstream, path, conn.query_string)
    req_content_type = get_content_type(conn.req_headers)
    outbound_headers = resolve_outbound_headers(opts, conn)

    # Notify handler of request start
    case notify_request_started(handler, %{
           upstream_url: upstream_url,
           method: conn.method,
           headers: outbound_headers,
           content_type: req_content_type,
           started_at: started_at
         }) do
      {:ok, handler_state} ->
        # Start Observer for request/response body observation
        req_accumulate? =
          Config.content_type_persistable?(
            req_content_type,
            config.persistable_content_types
          )

        {:ok, observer} =
          Observer.start_link(
            config: config,
            req_accumulate?: req_accumulate?
          )

        # Build request body with observer callback
        request_body = build_request_body(conn, observer)

        # Build Finch request
        request =
          Finch.build(
            method_atom(conn.method),
            upstream_url,
            outbound_headers,
            request_body
          )

        # Stream request and response with plain map accumulator
        acc = %{
          conn: conn,
          handler: if(handler, do: {elem(handler, 0), handler_state}, else: nil),
          observer: observer,
          status: nil,
          started_at: started_at,
          error: nil
        }

        result =
          Finch.stream_while(
            request,
            config.finch_name,
            acc,
            &handle_stream_message/2,
            receive_timeout: config.receive_timeout
          )

        case result do
          {:ok, acc} ->
            observations = Observer.finalize(observer)

            handler_state = handler_state(acc)

            # Notify handler of completion
            notify_response_finished(
              handler,
              %{
                request_observation: observations.request,
                response_observation: observations.response,
                error: nil,
                upstream_url: upstream_url,
                method: acc.conn.method,
                status: acc.conn.status,
                duration_us: System.monotonic_time(:microsecond) - started_at
              },
              handler_state
            )

            # Store observations in conn private
            acc.conn
            |> put_private(
              :weir_request_observation,
              observations.request
            )
            |> put_private(
              :weir_response_observation,
              observations.response
            )

          {:error, %Finch.Error{reason: reason}, acc}
          when reason in @timeout_reasons ->
            handle_error(acc, handler, %{
              upstream_url: upstream_url,
              method: conn.method,
              started_at: started_at,
              error: {:timeout, reason},
              status: 504,
              body: "Gateway Timeout"
            })

          {:error, %Mint.TransportError{reason: reason}, acc}
          when reason in @timeout_reasons ->
            handle_error(acc, handler, %{
              upstream_url: upstream_url,
              method: conn.method,
              started_at: started_at,
              error: {:timeout, reason},
              status: 504,
              body: "Gateway Timeout"
            })

          {:error, error, acc} ->
            handle_error(acc, handler, %{
              upstream_url: upstream_url,
              method: conn.method,
              started_at: started_at,
              error: error,
              status: 502,
              body: "Bad Gateway"
            })
        end

      {:reject, status, body, _handler_state} ->
        conn |> send_resp(status, body) |> halt()
    end
  end

  # Stream message handlers (replaces ResponseStreamer)

  defp handle_stream_message({:status, status}, acc) do
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

  defp resolve_handler(opts) do
    case Keyword.get(opts, :handler) do
      nil -> nil
      {module, args} when is_atom(module) -> {module, args}
      module when is_atom(module) -> {module, []}
    end
  end

  defp resolve_outbound_headers(opts, conn) do
    case Keyword.get(opts, :headers) do
      nil -> filter_request_headers(conn.req_headers)
      headers when is_list(headers) -> headers
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
            Weir.BodyStream.from_conn(conn,
              on_chunk: fn chunk ->
                Observer.request_chunk(observer, chunk)
              end
            )

          _ ->
            {:stream, []}
        end

      _ ->
        Weir.BodyStream.from_conn(conn,
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

  defp method_atom(method) do
    method |> String.downcase() |> String.to_existing_atom()
  end

  defp handler_state(%{handler: {_, state}}), do: state
  defp handler_state(_), do: nil

  defp handle_error(acc, handler, info) do
    observations = Observer.finalize(acc.observer)
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
        duration_us: System.monotonic_time(:microsecond) - info.started_at
      },
      handler_state
    )

    acc.conn |> send_resp(info.status, info.body) |> halt()
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
end

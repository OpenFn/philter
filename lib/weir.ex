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

  ## Observer Callbacks

  Implement `Weir.Observer` to hook into the proxy lifecycle:

    * `handle_request_started/1` - Called before sending to upstream
    * `handle_response_started/1` - Called on first byte received (TTFB)
    * `handle_response_finished/1` - Called when complete, with body observations

  Example:

      defmodule MyObserver do
        use Weir.Observer

        @impl true
        def handle_response_finished(result) do
          # result contains :request_observation and :response_observation
          # each with :hash, :size, :body, :preview, :duration_us
          :ok
        end
      end

  """

  import Plug.Conn
  require Logger

  alias Weir.{Config, Observation, ResponseStreamer}

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
          observer: module() | {module(), keyword()},
          finch_name: atom(),
          receive_timeout: pos_integer(),
          max_payload_size: pos_integer(),
          persistable_content_types: [String.t()],
          request_id: term()
        ]

  @doc """
  Proxies an HTTP request to an upstream server.

  Streams the request to upstream and the response back to the client. Call this
  after authentication or other pre-processing (unlike `Weir.ProxyPlug`).

  ## Examples

      # Basic proxy
      Weir.proxy(conn, upstream: "http://api.example.com")

      # With observer for logging/persistence
      Weir.proxy(conn,
        upstream: "http://api.example.com",
        observer: {MyObserver, user_id: user.id}
      )

      # Override timeout for slow endpoints
      Weir.proxy(conn,
        upstream: "http://api.example.com",
        receive_timeout: 60_000
      )

  ## Options

    * `:upstream` - Base URL of the upstream server. **Required.**

    * `:observer` - Observer module or `{module, args}` tuple for lifecycle callbacks.
      See `Weir.Observer` for the callback interface.

    * `:request_id` - Correlation ID for tracing. Default: auto-generated UUID.

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
  The observer's `handle_response_finished/1` is still called with the `:error` field set.
  """
  @spec proxy(Plug.Conn.t(), proxy_opts()) :: Plug.Conn.t()
  def proxy(conn, opts) do
    upstream = Keyword.fetch!(opts, :upstream)
    config = Config.resolve(opts)
    observer = resolve_observer(opts)
    request_id = Keyword.get(opts, :request_id, generate_request_id())

    started_at = System.monotonic_time(:microsecond)
    path = resolve_path(opts, conn)
    upstream_url = build_upstream_url(upstream, path, conn.query_string)
    req_content_type = get_content_type(conn.req_headers)

    # Notify observer of request start
    notify_request_started(observer, %{
      request_id: request_id,
      upstream_url: upstream_url,
      method: conn.method,
      headers: conn.req_headers,
      content_type: req_content_type,
      started_at: started_at
    })

    # Determine if request body should be accumulated
    req_accumulate? =
      Config.content_type_persistable?(req_content_type, config.persistable_content_types)

    # Get request body stream with observation
    {request_body, req_obs_agent} =
      get_request_body(conn, accumulate?: req_accumulate?, max_size: config.max_payload_size)

    # Build Finch request
    request =
      Finch.build(
        method_atom(conn.method),
        upstream_url,
        filter_request_headers(conn.req_headers, request_id),
        request_body
      )

    # Initialize response observation (will be configured when headers arrive)
    {:ok, resp_obs_agent} =
      Agent.start_link(fn ->
        # Start with no accumulation, will be updated when we see Content-Type
        Observation.new(accumulate?: false, max_size: config.max_payload_size)
      end)

    # Stream request and response
    initial_state =
      ResponseStreamer.new(conn, resp_obs_agent,
        observer: observer,
        request_id: request_id,
        config: config
      )

    result =
      Finch.stream_while(
        request,
        config.finch_name,
        initial_state,
        fn message, state -> ResponseStreamer.handle_message(message, state) end,
        receive_timeout: config.receive_timeout
      )

    case result do
      {:ok, final_state} ->
        conn = ResponseStreamer.get_conn(final_state)

        # Finalize observations
        req_observation = Weir.BodyStream.finalize_observation(req_obs_agent)
        resp_observation = Agent.get(resp_obs_agent, &Observation.finalize/1)
        Agent.stop(resp_obs_agent)

        # Notify observer of completion
        notify_response_finished(observer, %{
          request_id: request_id,
          request_observation: req_observation,
          response_observation: resp_observation,
          error: nil,
          upstream_url: upstream_url,
          method: conn.method,
          status: conn.status,
          duration_us: System.monotonic_time(:microsecond) - started_at
        })

        # Store observations in conn private
        conn
        |> put_private(:weir_request_observation, req_observation)
        |> put_private(:weir_response_observation, resp_observation)

      {:error, %Finch.Error{reason: reason}, _acc} when reason in @timeout_reasons ->
        handle_error(conn, req_obs_agent, resp_obs_agent, observer, %{
          request_id: request_id,
          upstream_url: upstream_url,
          method: conn.method,
          started_at: started_at,
          error: {:timeout, reason},
          status: 504,
          body: "Gateway Timeout"
        })

      {:error, %Mint.TransportError{reason: reason}, _acc} when reason in @timeout_reasons ->
        handle_error(conn, req_obs_agent, resp_obs_agent, observer, %{
          request_id: request_id,
          upstream_url: upstream_url,
          method: conn.method,
          started_at: started_at,
          error: {:timeout, reason},
          status: 504,
          body: "Gateway Timeout"
        })

      {:error, error, _acc} ->
        handle_error(conn, req_obs_agent, resp_obs_agent, observer, %{
          request_id: request_id,
          upstream_url: upstream_url,
          method: conn.method,
          started_at: started_at,
          error: error,
          status: 502,
          body: "Bad Gateway"
        })
    end
  end

  # Private functions

  defp resolve_observer(opts) do
    case Keyword.get(opts, :observer) do
      nil -> nil
      {module, args} when is_atom(module) -> {module, args}
      module when is_atom(module) -> {module, []}
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
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

  defp get_request_body(conn, opts) do
    case get_req_header(conn, "content-length") do
      ["0"] ->
        {{:stream, []}, start_empty_observation(opts)}

      [] ->
        case get_req_header(conn, "transfer-encoding") do
          ["chunked"] -> Weir.BodyStream.from_conn_with_observation(conn, opts)
          _ -> {{:stream, []}, start_empty_observation(opts)}
        end

      _ ->
        Weir.BodyStream.from_conn_with_observation(conn, opts)
    end
  end

  defp start_empty_observation(opts) do
    {:ok, agent} = Agent.start_link(fn -> Observation.new(opts) end)
    agent
  end

  defp filter_request_headers(headers, request_id) do
    headers
    |> Enum.reject(fn {key, _} ->
      String.downcase(key) in @hop_by_hop_headers
    end)
    |> Enum.map(fn {key, value} -> {String.downcase(key), value} end)
    |> List.keystore("x-request-id", 0, {"x-request-id", request_id})
  end

  defp method_atom(method) do
    method |> String.downcase() |> String.to_existing_atom()
  end

  defp handle_error(conn, req_obs_agent, resp_obs_agent, observer, info) do
    # Get partial observations
    req_observation = Weir.BodyStream.finalize_observation(req_obs_agent)
    resp_observation = Agent.get(resp_obs_agent, &Observation.finalize/1)
    Agent.stop(resp_obs_agent)

    # Notify observer
    notify_response_finished(observer, %{
      request_id: info.request_id,
      request_observation: req_observation,
      response_observation: resp_observation,
      error: info.error,
      upstream_url: info.upstream_url,
      method: info.method,
      status: nil,
      duration_us: System.monotonic_time(:microsecond) - info.started_at
    })

    conn |> send_resp(info.status, info.body) |> halt()
  end

  defp notify_request_started(nil, _metadata), do: :ok

  defp notify_request_started({module, _args}, metadata) do
    if function_exported?(module, :handle_request_started, 1) do
      module.handle_request_started(metadata)
    else
      :ok
    end
  end

  defp notify_response_finished(nil, _result), do: :ok

  defp notify_response_finished({module, _args}, result) do
    module.handle_response_finished(result)
  end
end

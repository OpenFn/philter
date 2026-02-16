defmodule Weir.ProxyPlug do
  @moduledoc """
  Plug interface for streaming HTTP proxying. Use this when you want to proxy
  all requests on a route without pre-processing logic.

  For controller-based usage with authentication or custom routing, see `Weir.proxy/2`.

  ## Router Usage

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        forward "/api/v1", Weir.ProxyPlug, upstream: "http://api.internal:4000"
        forward "/legacy", Weir.ProxyPlug,
          upstream: "http://legacy.example.com",
          receive_timeout: 30_000
      end

  ## Options

    * `:upstream` - Base URL of upstream server (required)
    * `:handler` - Handler module or `{module, state}` tuple (optional)
    * `:finch_name` - Finch pool name (default: `Weir.Finch`)
    * `:receive_timeout` - Response timeout in ms (default: `15_000`)
    * `:max_payload_size` - Max body size for accumulation (default: `1_048_576`)
    * `:persistable_content_types` - Content types to accumulate (default: JSON, XML, text)

  See `Weir.Config` for global defaults and application configuration.

  ## Accessing Observations

  After proxying, observations are available in `conn.private`:

      plug :fetch_observations

      defp fetch_observations(conn, _opts) do
        req_obs = conn.private[:weir_request_observation]
        resp_obs = conn.private[:weir_response_observation]
        # req_obs and resp_obs contain: hash, size, preview, timing
        conn
      end

  ## Comparison with Weir.proxy/2

  Use `Weir.ProxyPlug` when:
    * Forwarding entire route prefixes without pre-processing
    * No authentication or authorization is needed before proxying

  Use `Weir.proxy/2` when:
    * You need authentication before proxying
    * You need to dynamically determine the upstream URL
    * You want to inspect or modify the request before forwarding

  Example with `Weir.proxy/2`:

      def proxy(conn, _params) do
        with {:ok, user} <- authenticate(conn),
             {:ok, upstream} <- resolve_upstream(user) do
          Weir.proxy(conn, upstream: upstream)
        end
      end
  """

  @behaviour Plug

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

  @impl true
  def init(opts) do
    upstream = Keyword.fetch!(opts, :upstream)
    handler = resolve_handler(opts)

    %{
      upstream: upstream,
      handler: handler,
      opts: opts
    }
  end

  @impl true
  def call(conn, %{upstream: upstream, handler: handler, opts: opts}) do
    config = Config.resolve(opts)
    request_id = generate_request_id()
    started_at = System.monotonic_time(:microsecond)
    path = resolve_path(opts, conn)
    upstream_url = build_upstream_url(upstream, path, conn.query_string)
    req_content_type = get_content_type(conn.req_headers)

    # Notify handler of request start
    case notify_request_started(handler, %{
           request_id: request_id,
           upstream_url: upstream_url,
           method: conn.method,
           headers: conn.req_headers,
           content_type: req_content_type,
           started_at: started_at
         }) do
      {:ok, handler_state} ->
        # Determine if request body should be accumulated
        req_accumulate? =
          Config.content_type_persistable?(
            req_content_type,
            config.persistable_content_types
          )

        # Get request body stream with observation
        {request_body, req_obs_agent} =
          get_request_body(conn,
            accumulate?: req_accumulate?,
            max_size: config.max_payload_size
          )

        # Build Finch request
        request =
          Finch.build(
            method_atom(conn.method),
            upstream_url,
            filter_request_headers(conn.req_headers, request_id),
            request_body
          )

        # Initialize response observation (configured when headers arrive)
        {:ok, resp_obs_agent} =
          Agent.start_link(fn ->
            Observation.new(accumulate?: false, max_size: config.max_payload_size)
          end)

        # Stream request and response
        case stream_request(
               conn,
               request,
               config,
               resp_obs_agent,
               handler,
               request_id,
               handler_state,
               started_at
             ) do
          {:ok, conn, final_handler_state} ->
            # Finalize observations
            req_observation = Weir.BodyStream.finalize_observation(req_obs_agent)
            resp_observation = Agent.get(resp_obs_agent, &Observation.finalize/1)
            Agent.stop(resp_obs_agent)

            # Notify handler of completion
            notify_response_finished(
              handler,
              %{
                request_id: request_id,
                request_observation: req_observation,
                response_observation: resp_observation,
                error: nil,
                upstream_url: upstream_url,
                method: conn.method,
                status: conn.status,
                duration_us: System.monotonic_time(:microsecond) - started_at
              },
              final_handler_state
            )

            # Store observations in conn private for later retrieval
            conn
            |> put_private(:weir_request_observation, req_observation)
            |> put_private(:weir_response_observation, resp_observation)

          {:error, %Finch.Error{reason: reason}} when reason in @timeout_reasons ->
            handle_error(conn, req_obs_agent, resp_obs_agent, handler, handler_state, %{
              request_id: request_id,
              upstream_url: upstream_url,
              method: conn.method,
              started_at: started_at,
              error: {:timeout, reason},
              status: 504,
              body: "Gateway Timeout"
            })

          {:error, %Mint.TransportError{reason: reason}} when reason in @timeout_reasons ->
            handle_error(conn, req_obs_agent, resp_obs_agent, handler, handler_state, %{
              request_id: request_id,
              upstream_url: upstream_url,
              method: conn.method,
              started_at: started_at,
              error: {:timeout, reason},
              status: 504,
              body: "Gateway Timeout"
            })

          {:error, error} ->
            handle_error(conn, req_obs_agent, resp_obs_agent, handler, handler_state, %{
              request_id: request_id,
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

  defp resolve_handler(opts) do
    case Keyword.get(opts, :handler) do
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

  defp stream_request(
         conn,
         request,
         config,
         resp_obs_agent,
         handler,
         request_id,
         handler_state,
         started_at
       ) do
    initial_state =
      ResponseStreamer.new(conn, resp_obs_agent,
        handler: handler,
        request_id: request_id,
        config: config,
        handler_state: handler_state,
        started_at: started_at
      )

    result =
      Finch.stream_while(
        request,
        config.finch_name,
        initial_state,
        fn message, state ->
          ResponseStreamer.handle_message(message, state)
        end,
        receive_timeout: config.receive_timeout
      )

    case result do
      {:ok, final_state} ->
        {:ok, ResponseStreamer.get_conn(final_state),
         ResponseStreamer.get_handler_state(final_state)}

      {:error, exception, _acc} ->
        {:error, exception}
    end
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

  defp handle_error(conn, req_obs_agent, resp_obs_agent, handler, handler_state, info) do
    # Get partial observations
    req_observation = Weir.BodyStream.finalize_observation(req_obs_agent)
    resp_observation = Agent.get(resp_obs_agent, &Observation.finalize/1)
    Agent.stop(resp_obs_agent)

    # Notify handler
    notify_response_finished(
      handler,
      %{
        request_id: info.request_id,
        request_observation: req_observation,
        response_observation: resp_observation,
        error: info.error,
        upstream_url: info.upstream_url,
        method: info.method,
        status: nil,
        duration_us: System.monotonic_time(:microsecond) - info.started_at
      },
      handler_state
    )

    conn |> send_resp(info.status, info.body) |> halt()
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

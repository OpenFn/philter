defmodule Weir.ResponseStreamer do
  @moduledoc false
  # Internal module: Processes Finch stream messages and forwards to client.
  #
  # Handles {:status, _}, {:headers, _}, {:data, _} messages from Finch,
  # filters hop-by-hop headers, sends chunked response to client, and
  # updates observation agent with response data.

  import Plug.Conn

  alias Weir.{Config, Observation}

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

  defstruct [
    :conn,
    :obs_agent,
    :status,
    :headers_sent,
    :error,
    :handler,
    :request_id,
    :config,
    :response_headers,
    :ttfb_notified,
    :handler_agent,
    :started_at
  ]

  @type t :: %__MODULE__{
          conn: Plug.Conn.t(),
          obs_agent: pid(),
          status: non_neg_integer() | nil,
          headers_sent: boolean(),
          error: term() | nil,
          handler: {module(), term()} | nil,
          request_id: term(),
          config: map() | nil,
          response_headers: [{String.t(), String.t()}] | nil,
          ttfb_notified: boolean(),
          handler_agent: pid() | nil,
          started_at: integer() | nil
        }

  @doc "Creates new state with conn, observation agent, and options."
  @spec new(Plug.Conn.t(), pid(), keyword()) :: t()
  def new(conn, obs_agent, opts \\ []) do
    %__MODULE__{
      conn: conn,
      obs_agent: obs_agent,
      status: nil,
      headers_sent: false,
      error: nil,
      handler: Keyword.get(opts, :handler),
      request_id: Keyword.get(opts, :request_id),
      config: Keyword.get(opts, :config),
      response_headers: nil,
      ttfb_notified: false,
      handler_agent: Keyword.get(opts, :handler_agent),
      started_at: Keyword.get(opts, :started_at)
    }
  end

  @doc "Handles Finch stream message. Returns {:cont, state} or {:halt, state}."
  @spec handle_message(term(), t()) :: {:cont | :halt, t()}
  def handle_message({:status, status}, state) do
    {:cont, %{state | status: status}}
  end

  def handle_message({:headers, headers}, state) do
    filtered_headers = filter_response_headers(headers)
    content_type = get_content_type(headers)

    # Configure observation accumulation based on content type
    configure_accumulation(state, content_type)

    # Notify handler of response start (TTFB)
    state = notify_response_started(state, content_type)

    updated_conn =
      state.conn
      |> apply_resp_headers(filtered_headers)
      |> send_chunked(state.status)

    {:cont, %{state | conn: updated_conn, headers_sent: true, response_headers: headers}}
  end

  def handle_message({:data, chunk}, state) do
    # Update response observation
    Agent.update(state.obs_agent, fn obs -> Weir.Observation.update(obs, chunk) end)

    # Forward chunk to client
    case chunk(state.conn, chunk) do
      {:ok, updated_conn} ->
        {:cont, %{state | conn: updated_conn}}

      {:error, reason} ->
        {:halt, %{state | error: reason}}
    end
  end

  def handle_message({:trailers, _trailers}, state) do
    {:cont, state}
  end

  @doc false
  @spec get_conn(t()) :: Plug.Conn.t()
  def get_conn(state), do: state.conn

  @doc false
  @spec get_error(t()) :: term() | nil
  def get_error(state), do: state.error

  @doc false
  @spec has_error?(t()) :: boolean()
  def has_error?(state), do: state.error != nil

  # Private helpers

  defp apply_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      put_resp_header(conn, String.downcase(key), value)
    end)
  end

  defp filter_response_headers(headers) do
    headers
    |> Enum.reject(fn {key, _} ->
      key = String.downcase(key)
      key in @hop_by_hop_headers or key == "content-length"
    end)
    |> Enum.map(fn {key, value} -> {String.downcase(key), value} end)
  end

  defp get_content_type(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, value} ->
        value

      nil ->
        # Try lowercase
        case List.keyfind(headers, "Content-Type", 0) do
          {_, value} -> value
          nil -> nil
        end
    end
  end

  defp configure_accumulation(%{config: nil}, _content_type), do: :ok

  defp configure_accumulation(%{obs_agent: agent, config: config}, content_type) do
    persistable_types = Map.get(config, :persistable_content_types, [])
    max_size = Map.get(config, :max_payload_size, 1_048_576)

    accumulate? = Config.content_type_persistable?(content_type, persistable_types)

    # Reinitialize observation with correct accumulation settings
    Agent.update(agent, fn _obs ->
      Observation.new(accumulate?: accumulate?, max_size: max_size)
    end)
  end

  defp notify_response_started(%{handler: nil} = state, _content_type), do: state
  defp notify_response_started(%{ttfb_notified: true} = state, _content_type), do: state

  defp notify_response_started(state, content_type) do
    {module, _args} = state.handler
    ttfb = System.monotonic_time(:microsecond) - state.started_at

    if function_exported?(module, :handle_response_started, 2) do
      call_response_started(state, module, content_type, ttfb)
    else
      %{state | ttfb_notified: true}
    end
  end

  defp call_response_started(state, module, content_type, ttfb) do
    handler_state = Agent.get(state.handler_agent, & &1)

    {:ok, new_handler_state} =
      module.handle_response_started(
        %{
          request_id: state.request_id,
          status: state.status,
          headers: state.response_headers || [],
          content_type: content_type,
          time_to_first_byte_us: ttfb
        },
        handler_state
      )

    Agent.update(state.handler_agent, fn _ -> new_handler_state end)
    %{state | ttfb_notified: true}
  end
end

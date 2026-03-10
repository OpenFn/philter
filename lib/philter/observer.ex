defmodule Philter.Observer do
  @moduledoc false
  # Linked process that accumulates request and response body observations
  # for a single proxy request. Replaces the previous 3-Agent approach with
  # a single ephemeral process that uses a recursive receive loop.

  alias Philter.{Config, Observation}

  @finalize_timeout 5_000

  @doc """
  Spawns a linked observer process.

  ## Options

    * `:config` — resolved `Philter.Config` map with `:persistable_content_types`
      and `:max_payload_size`
    * `:req_accumulate?` — whether to accumulate the full request body
      (default: `false`)

  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    req_accumulate? = Keyword.get(opts, :req_accumulate?, false)

    state = %{
      req_obs:
        Observation.new(
          accumulate?: req_accumulate?,
          max_size: config.max_payload_size
        ),
      resp_obs: Observation.new(accumulate?: false),
      config: config
    }

    pid = spawn_link(fn -> loop(state) end)
    {:ok, pid}
  end

  @doc """
  Sends a request body chunk to the observer (fire-and-forget).
  """
  @spec request_chunk(pid(), binary()) :: :ok
  def request_chunk(pid, chunk) do
    send(pid, {:req_chunk, chunk})
    :ok
  end

  @doc """
  Sends a response body chunk to the observer (fire-and-forget).
  """
  @spec response_chunk(pid(), binary()) :: :ok
  def response_chunk(pid, chunk) do
    send(pid, {:resp_chunk, chunk})
    :ok
  end

  @doc """
  Notifies the observer that response headers have arrived, allowing it
  to reconfigure response body accumulation based on the content-type.
  """
  @spec response_started(pid(), [{String.t(), String.t()}]) :: :ok
  def response_started(pid, headers) do
    send(pid, {:resp_started, headers})
    :ok
  end

  @doc """
  Synchronously finalizes both observations and returns the result.

  The observer process exits normally after responding.
  """
  @spec finalize(pid()) :: %{
          request: Philter.Handler.body_observation(),
          response: Philter.Handler.body_observation()
        }
  def finalize(pid) do
    ref = make_ref()
    send(pid, {:finalize, self(), ref})

    receive do
      {^ref, result} -> result
    after
      @finalize_timeout ->
        raise "Observer finalize timed out after #{@finalize_timeout}ms"
    end
  end

  # -- Private ---------------------------------------------------------------

  defp loop(state) do
    receive do
      {:req_chunk, chunk} ->
        loop(%{state | req_obs: Observation.update(state.req_obs, chunk)})

      {:resp_chunk, chunk} ->
        loop(%{state | resp_obs: Observation.update(state.resp_obs, chunk)})

      {:resp_started, headers} ->
        content_type = get_content_type(headers)

        accumulate? =
          Config.content_type_persistable?(
            content_type,
            state.config.persistable_content_types
          )

        resp_obs =
          Observation.new(
            accumulate?: accumulate?,
            max_size: state.config.max_payload_size
          )

        loop(%{state | resp_obs: resp_obs})

      {:finalize, caller_pid, ref} ->
        result = %{
          request: Observation.finalize(state.req_obs),
          response: Observation.finalize(state.resp_obs)
        }

        send(caller_pid, {ref, result})
        # Process exits normally by returning from the function
    end
  end

  defp get_content_type(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, value} ->
        value

      nil ->
        case List.keyfind(headers, "Content-Type", 0) do
          {_, value} -> value
          nil -> nil
        end
    end
  end
end

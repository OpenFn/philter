defmodule Weir.BodyStream do
  @moduledoc false
  # Internal module: Adapts Plug.Conn request body to Finch stream format.
  #
  # Reads the request body via Plug.Conn.read_body/2 and wraps it as
  # `{:stream, enumerable}` for Finch. Supports an `:on_chunk` callback
  # for observation (hash/size capture) during streaming.

  # Read 64KB chunks
  @chunk_size 64_000

  @doc """
  Creates `{:stream, enumerable}` from a Plug.Conn for Finch.

  Options:
  - `:on_chunk` - callback for each chunk (default: no-op)
  - `:chunk_size` - bytes per read (default: 64KB)
  """
  def from_conn(conn, opts \\ []) do
    on_chunk = Keyword.get(opts, :on_chunk, fn _chunk -> :ok end)
    chunk_size = Keyword.get(opts, :chunk_size, @chunk_size)

    stream =
      Stream.resource(
        fn -> {:continue, conn} end,
        fn
          {:done, _conn} ->
            {:halt, nil}

          {:continue, conn} ->
            case Plug.Conn.read_body(conn, length: chunk_size) do
              {:more, chunk, conn} ->
                on_chunk.(chunk)
                {[chunk], {:continue, conn}}

              # Empty chunk means no more data
              {:ok, "", conn} ->
                {:halt, conn}

              {:ok, chunk, conn} ->
                on_chunk.(chunk)
                {[chunk], {:done, conn}}

              {:error, reason} ->
                raise "Failed to read request body: #{inspect(reason)}"
            end
        end,
        fn _ -> :ok end
      )

    {:stream, stream}
  end

  @doc """
  Creates streaming body with an observation agent.

  Returns `{{:stream, enumerable}, obs_agent}`. The agent accumulates
  observation state; call `finalize_observation/1` when done.

  Options (in addition to `from_conn/2`):
  - `:accumulate?` - collect full body (default: false)
  - `:max_size` - byte limit for accumulation (default: 1MB)
  """
  def from_conn_with_observation(conn, opts \\ []) do
    accumulate? = Keyword.get(opts, :accumulate?, false)
    max_size = Keyword.get(opts, :max_size, 1_048_576)

    {:ok, obs_agent} =
      Agent.start_link(fn ->
        Weir.Observation.new(accumulate?: accumulate?, max_size: max_size)
      end)

    on_chunk = fn chunk ->
      Agent.update(obs_agent, fn obs -> Weir.Observation.update(obs, chunk) end)
    end

    opts = Keyword.put(opts, :on_chunk, on_chunk)
    body = from_conn(conn, opts)

    {body, obs_agent}
  end

  @doc "Finalizes observation, stops agent, returns observation result map."
  def finalize_observation(obs_agent) do
    result = Agent.get(obs_agent, fn obs -> Weir.Observation.finalize(obs) end)
    Agent.stop(obs_agent)
    result
  end
end

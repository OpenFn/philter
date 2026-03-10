defmodule Philter.BodyStream do
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
end

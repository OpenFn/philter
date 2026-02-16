defmodule Weir.Observation do
  @moduledoc false
  # Internal module: Incremental observation capture for streaming bodies.
  #
  # Captures hash (SHA256), preview (first 64KB), size, and timing data
  # incrementally as chunks arrive. Optionally accumulates the full body
  # if under a size threshold.
  #
  # ## Body Accumulation
  #
  # When `accumulate?: true`:
  # - Body chunks are collected in an iolist
  # - If size exceeds `max_size`, accumulated data is discarded mid-stream
  # - `finalize/1` returns `:body` as binary if accumulated, nil otherwise
  #
  # When `accumulate?: false` (default):
  # - Only hash/preview/size/timing are captured
  # - `:body` is always nil in finalized result

  # 64KB preview
  @preview_size 64 * 1024

  defstruct [
    :hash_state,
    :preview,
    :size,
    :started_at,
    :first_byte_at,
    # Accumulation fields
    :accumulate?,
    :accumulated_body,
    :max_size,
    :exceeded_threshold?
  ]

  @type t :: %__MODULE__{
          hash_state: term(),
          preview: binary(),
          size: non_neg_integer(),
          started_at: integer(),
          first_byte_at: integer() | nil,
          accumulate?: boolean(),
          accumulated_body: iodata() | nil,
          max_size: non_neg_integer(),
          exceeded_threshold?: boolean()
        }

  @type accumulation_opts :: [
          accumulate?: boolean(),
          max_size: non_neg_integer()
        ]

  @doc """
  Creates a new observation state.

  Options:
  - `:accumulate?` - collect full body in memory (default: false)
  - `:max_size` - byte limit before discarding accumulated body (default: 1MB)
  """
  @spec new(accumulation_opts()) :: t()
  def new(opts \\ []) do
    accumulate? = Keyword.get(opts, :accumulate?, false)
    max_size = Keyword.get(opts, :max_size, 1_048_576)

    %__MODULE__{
      hash_state: :crypto.hash_init(:sha256),
      preview: <<>>,
      size: 0,
      started_at: System.monotonic_time(:microsecond),
      first_byte_at: nil,
      accumulate?: accumulate?,
      accumulated_body: if(accumulate?, do: [], else: nil),
      max_size: max_size,
      exceeded_threshold?: false
    }
  end

  @doc """
  Updates observation with a chunk. Updates hash, preview, size, timing,
  and accumulated body (if enabled and under threshold).
  """
  @spec update(t(), binary()) :: t()
  def update(%__MODULE__{} = obs, chunk) when is_binary(chunk) do
    now = System.monotonic_time(:microsecond)
    chunk_size = byte_size(chunk)
    new_size = obs.size + chunk_size

    {accumulated_body, exceeded?} = update_accumulated(obs, chunk, new_size)

    %__MODULE__{
      hash_state: :crypto.hash_update(obs.hash_state, chunk),
      preview: capture_preview(obs.preview, chunk),
      size: new_size,
      started_at: obs.started_at,
      first_byte_at: obs.first_byte_at || now,
      accumulate?: obs.accumulate?,
      accumulated_body: accumulated_body,
      max_size: obs.max_size,
      exceeded_threshold?: exceeded?
    }
  end

  defp update_accumulated(%{accumulate?: false}, _chunk, _new_size) do
    {nil, false}
  end

  defp update_accumulated(%{exceeded_threshold?: true}, _chunk, _new_size) do
    # Already exceeded, stay discarded
    {nil, true}
  end

  defp update_accumulated(%{accumulated_body: body, max_size: max}, _chunk, new_size)
       when new_size > max do
    # Just exceeded threshold - discard accumulated data
    _ = body
    {nil, true}
  end

  defp update_accumulated(%{accumulated_body: body}, chunk, _new_size) do
    # Under threshold - keep accumulating
    {[body, chunk], false}
  end

  @doc """
  Finalizes observation and returns result map.

  Returns:
  - `:hash` - SHA256 hex string
  - `:size` - total bytes
  - `:preview` - first 64KB (UTF-8 safe)
  - `:body` - full body binary if accumulated, nil otherwise
  - `:duration_us` - total microseconds
  - `:time_to_first_byte_us` - microseconds to first chunk (nil if no data)
  """
  @spec finalize(t()) :: Weir.Handler.body_observation()
  def finalize(%__MODULE__{} = obs) do
    hash = obs.hash_state |> :crypto.hash_final() |> Base.encode16(case: :lower)
    body = finalize_body(obs)
    preview = finalize_preview(obs.preview)

    %{
      hash: hash,
      preview: preview,
      size: obs.size,
      body: body,
      duration_us: System.monotonic_time(:microsecond) - obs.started_at,
      time_to_first_byte_us: time_to_first_byte(obs)
    }
  end

  defp finalize_body(%{accumulate?: false}), do: nil
  defp finalize_body(%{exceeded_threshold?: true}), do: nil
  defp finalize_body(%{accumulated_body: body}), do: IO.iodata_to_binary(body)

  defp finalize_preview(preview) do
    # Ensure preview is valid UTF-8 by trimming any incomplete sequences
    case Weir.UTF8.ensure_valid(preview) do
      {:ok, valid} -> valid
      # Keep as-is if it's binary data
      {:error, _} -> preview
    end
  end

  defp capture_preview(existing, _chunk) when byte_size(existing) >= @preview_size do
    existing
  end

  defp capture_preview(existing, chunk) do
    remaining = @preview_size - byte_size(existing)
    to_capture = min(remaining, byte_size(chunk))
    <<captured::binary-size(to_capture), _rest::binary>> = chunk
    existing <> captured
  end

  defp time_to_first_byte(%{first_byte_at: nil}), do: nil
  defp time_to_first_byte(%{first_byte_at: first, started_at: started}), do: first - started
end

defmodule Philter.Timing do
  @moduledoc """
  Per-phase timing capture for proxy requests.

  Captures pool checkout, connection, send, and receive durations from
  the underlying HTTP client's telemetry events.

  Uses a single globally-attached telemetry handler (attached lazily on
  first use). Per-request opt-in is via a process dictionary flag — when
  no proxy has opted in, the handler is a single `Process.get/1` returning
  nil.

  Timing capture is single-flight-per-process: only one `proxy/2` call
  per process can capture timing at a time. The `:philter_timing_ref`
  process dictionary key is shared, so a reentrant `proxy/2` call in the
  same process would overwrite the ref. This is by design — Plug request
  processes handle one request at a time.
  """

  @typedoc false
  @type t :: %{
          queue_us: non_neg_integer() | nil,
          connect_us: non_neg_integer() | nil,
          send_us: non_neg_integer() | nil,
          recv_us: non_neg_integer() | nil,
          idle_time_us: non_neg_integer() | nil,
          reused_connection?: boolean()
        }

  @events [
    [:finch, :queue, :stop],
    [:finch, :connect, :stop],
    [:finch, :send, :stop],
    [:finch, :recv, :stop],
    [:finch, :reused_connection]
  ]

  @handler_id "philter-timing"

  ## Lazy global handler attachment

  @doc false
  @spec ensure_attached() :: :ok
  def ensure_attached do
    case :persistent_term.get({__MODULE__, :attached}, false) do
      true ->
        :ok

      false ->
        case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil) do
          :ok -> :ok
          {:error, :already_exists} -> :ok
        end

        :persistent_term.put({__MODULE__, :attached}, true)
    end
  end

  ## Per-request opt-in / collection

  @doc false
  @spec start_capture() :: reference()
  def start_capture do
    ref = make_ref()
    Process.put(:philter_timing_ref, ref)
    ref
  end

  @doc false
  @spec collect(reference()) :: t()
  def collect(ref) do
    Process.delete(:philter_timing_ref)

    result = %{
      queue_us: get_duration(ref, [:finch, :queue, :stop]),
      connect_us: get_duration(ref, [:finch, :connect, :stop]),
      send_us: get_duration(ref, [:finch, :send, :stop]),
      recv_us: get_duration(ref, [:finch, :recv, :stop]),
      idle_time_us: get_idle_time(ref),
      reused_connection?: get_reused(ref)
    }

    cleanup(ref)
    result
  end

  ## Telemetry handler (called for ALL finch events in any process)

  @doc false
  def handle_event(event, measurements, _metadata, _config) do
    case Process.get(:philter_timing_ref) do
      nil -> :ok
      ref -> Process.put({ref, event}, measurements)
    end
  end

  ## Private helpers

  # Read duration from stored measurements without deleting — other fields
  # (e.g. idle_time on queue) may be needed from the same measurements map.
  # cleanup/1 handles deletion after all fields are extracted.
  defp get_duration(ref, event) do
    case Process.get({ref, event}) do
      nil ->
        nil

      %{duration: duration} ->
        System.convert_time_unit(duration, :native, :microsecond)
    end
  end

  # idle_time is part of the [:finch, :queue, :stop] measurements map
  # alongside duration. Read from the same stored measurements.
  defp get_idle_time(ref) do
    case Process.get({ref, [:finch, :queue, :stop]}) do
      nil ->
        nil

      %{idle_time: idle_time} ->
        System.convert_time_unit(idle_time, :native, :microsecond)

      _no_idle_time ->
        nil
    end
  end

  defp get_reused(ref) do
    case Process.get({ref, [:finch, :reused_connection]}) do
      nil -> false
      _measurements -> true
    end
  end

  defp cleanup(ref) do
    for event <- @events, do: Process.delete({ref, event})
    :ok
  end
end

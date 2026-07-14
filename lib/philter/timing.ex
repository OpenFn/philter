defmodule Philter.Timing do
  @moduledoc """
  Per-phase timing for proxy requests.

  Durations are measured directly around the Mint transport calls using
  `System.monotonic_time/1`: `connect_us` (TCP + TLS handshake), `send_us`
  (request send) and `recv_us` (response receive). There is no connection
  pool, so `queue_us` and `idle_time_us` are always `nil` and
  `reused_connection?` is always `false`.

  Populated only when `collect_timing: true` is passed to `Philter.proxy/2`;
  otherwise every phase field is `nil`.
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

  @doc """
  Builds a phase-timing map from measured microsecond durations.

  `queue_us` and `idle_time_us` are always `nil` and `reused_connection?` is
  always `false` because the Mint transport establishes a fresh connection per
  request with no pool.
  """
  @spec new(non_neg_integer() | nil, non_neg_integer() | nil, non_neg_integer() | nil) :: t()
  def new(connect_us, send_us, recv_us) do
    %{
      queue_us: nil,
      connect_us: connect_us,
      send_us: send_us,
      recv_us: recv_us,
      idle_time_us: nil,
      reused_connection?: false
    }
  end
end

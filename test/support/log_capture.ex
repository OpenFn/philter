defmodule Philter.LogCapture do
  @moduledoc """
  Log capture scoped to the calling process.

  `ExUnit.CaptureLog` installs one global `:logger` handler and fans every log
  event out to every capture that is currently open, filtering only on level.
  The pid it takes is monitored for cleanup, never consulted when routing. A
  capture in one async test therefore sees log lines emitted by every other
  test running at the same moment, which is why `ExUnit.CaptureLog` documents
  `=~` as the only safe assertion under `async: true`.

  That makes "nothing was logged" unassertable with the built-in capture. This
  attaches its own handler filtered to the emitting pid, so the capture holds
  only what the calling process logged. Philter logs entirely from the process
  that calls `Philter.proxy/2`, so filtering on `self()` catches all of it.
  """

  @doc """
  Runs `fun`, returning `{result, log}` where `log` holds only the lines the
  calling process emitted.
  """
  @spec with_own_log((-> result)) :: {result, String.t()} when result: var
  def with_own_log(fun) when is_function(fun, 0) do
    owner = self()
    id = :"philter_own_log_#{System.unique_integer([:positive])}"

    :ok =
      :logger.add_handler(id, __MODULE__, %{
        level: :all,
        config: %{owner: owner},
        filters: [own_pid: {&__MODULE__.__filter_pid__/2, owner}],
        filter_default: :stop
      })

    try do
      result = fun.()
      :ok = Logger.flush()
      {result, drain([])}
    after
      :logger.remove_handler(id)
      # If fun raised, its lines are still queued; a later capture in this same
      # test would otherwise drain them as its own.
      drain([])
    end
  end

  @doc """
  Runs `fun` and returns only the lines the calling process emitted.
  """
  @spec capture_own_log((-> any())) :: String.t()
  def capture_own_log(fun) when is_function(fun, 0) do
    {_result, log} = with_own_log(fun)
    log
  end

  @doc false
  def __filter_pid__(%{meta: %{pid: pid}} = event, pid), do: event
  def __filter_pid__(_event, _owner), do: :stop

  @doc false
  def log(%{level: level, msg: msg}, %{config: %{owner: owner}}) do
    send(owner, {__MODULE__, "[#{level}] #{format(msg)}"})
  end

  defp format({:string, chardata}), do: IO.iodata_to_binary(chardata)

  defp format({format, args}) when is_list(format),
    do: format |> :io_lib.format(args) |> IO.iodata_to_binary()

  defp format({:report, report}), do: inspect(report)

  defp drain(acc) do
    receive do
      {__MODULE__, line} -> drain([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end

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
  module keeps one `:logger` handler installed for the whole run. `:logger`
  calls handlers in the process that logged, so the handler checks that
  process's dictionary and only forwards lines from processes that are
  capturing. Philter logs entirely from the process that calls
  `Philter.proxy/2`, so this catches all of it.

  Adding and removing a handler per capture would race with `Logger.flush/0`
  on older Elixir versions, which lists the handlers and then reads each one's
  config, so a handler removed by another test in between makes it crash.
  """

  @handler_id :philter_own_log
  @capturing {__MODULE__, :capturing}

  @doc """
  Installs the shared handler. Call once from `test_helper.exs`.
  """
  @spec install() :: :ok
  def install do
    :ok = :logger.add_handler(@handler_id, __MODULE__, %{level: :all})
  end

  @doc """
  Runs `fun`, returning `{result, log}` where `log` holds only the lines the
  calling process emitted.
  """
  @spec with_own_log((-> result)) :: {result, String.t()} when result: var
  def with_own_log(fun) when is_function(fun, 0) do
    Process.put(@capturing, true)

    try do
      result = fun.()
      {result, drain([])}
    after
      Process.delete(@capturing)
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
  def log(%{level: level, msg: msg}, _config) do
    if Process.get(@capturing), do: send(self(), {__MODULE__, "[#{level}] #{format(msg)}"})
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

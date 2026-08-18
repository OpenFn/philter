defmodule Philter.LogCaptureTest do
  use ExUnit.Case, async: true

  require Logger
  import Philter.LogCapture

  test "captures lines logged by the calling process" do
    log = capture_own_log(fn -> Logger.error("mine") end)

    assert log =~ "[error] mine"
  end

  test "returns the value alongside the log" do
    assert {:ok, log} = with_own_log(fn -> Logger.warning("both") && :ok end)
    assert log =~ "both"
  end

  test "ignores lines logged by other processes" do
    parent = self()

    noisy =
      spawn(fn ->
        receive do: (:go -> :ok)
        for _ <- 1..200, do: Logger.error("noise from elsewhere")
        send(parent, :noisy_done)
      end)

    log =
      capture_own_log(fn ->
        send(noisy, :go)
        assert_receive :noisy_done, 5_000
      end)

    assert log == ""
  end

  test "a raise inside the capture does not leak lines into the next capture" do
    assert_raise RuntimeError, fn ->
      capture_own_log(fn ->
        Logger.error("leaked")
        raise "boom"
      end)
    end

    assert capture_own_log(fn -> :ok end) == ""
  end
end

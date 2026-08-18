defmodule Philter.LogSuppressionTest do
  # capture_log/2 captures Logger output from every process, so asserting on an
  # empty capture only holds while no other test is logging. These run serially.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, upstream: "http://localhost:#{bypass.port}"}
  end

  test "log_level: false produces no log output", %{bypass: bypass, upstream: upstream} do
    Bypass.expect(bypass, "GET", "/silent", fn conn ->
      send_resp(conn, 200, "ok")
    end)

    log =
      capture_log([level: :debug], fn ->
        conn(:get, "/silent")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          log_level: false
        )
      end)

    assert log == ""
  end

  test "error log is suppressed when log_level: false" do
    log =
      capture_log([level: :error], fn ->
        conn(:get, "/fail")
        |> Philter.proxy(
          upstream: "http://localhost:59999",
          finch_name: Philter.TestFinch,
          log_level: false
        )
      end)

    assert log == ""
  end
end

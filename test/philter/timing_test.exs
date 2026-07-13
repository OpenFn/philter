defmodule Philter.TimingTest do
  use ExUnit.Case, async: true

  alias Philter.Timing

  describe "new/3" do
    test "populates connect/send/recv durations from measured microseconds" do
      result = Timing.new(20, 30, 40)

      assert result.connect_us == 20
      assert result.send_us == 30
      assert result.recv_us == 40
    end

    test "queue_us and idle_time_us are always nil (no connection pool)" do
      result = Timing.new(1, 2, 3)

      assert result.queue_us == nil
      assert result.idle_time_us == nil
    end

    test "reused_connection? is always false (fresh connection per request)" do
      result = Timing.new(1, 2, 3)

      assert result.reused_connection? == false
    end

    test "phase durations may be nil when a phase was never reached" do
      result = Timing.new(15, nil, nil)

      assert result.connect_us == 15
      assert result.send_us == nil
      assert result.recv_us == nil
    end
  end
end

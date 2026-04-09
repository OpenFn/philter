defmodule Philter.TimingTest do
  use ExUnit.Case, async: true

  alias Philter.Timing

  setup do
    Timing.ensure_attached()
    :ok
  end

  describe "ensure_attached/0" do
    test "calling twice does not crash" do
      assert :ok = Timing.ensure_attached()
      assert :ok = Timing.ensure_attached()
    end
  end

  describe "handle_event/4" do
    test "does nothing when :philter_timing_ref is not in process dictionary" do
      # Ensure no timing ref is set
      Process.delete(:philter_timing_ref)

      # Fire an event — should be a no-op, not a crash
      :telemetry.execute([:finch, :queue, :stop], %{duration: 100}, %{})

      # Nothing should be stored in the process dictionary for any ref
      assert Process.get(:philter_timing_ref) == nil
    end
  end

  describe "capture and collect round-trip" do
    test "events are captured and collect returns populated map" do
      one_us_native = System.convert_time_unit(1, :microsecond, :native)

      ref = Timing.start_capture()

      :telemetry.execute(
        [:finch, :queue, :stop],
        %{duration: one_us_native * 10, idle_time: one_us_native * 2},
        %{}
      )

      :telemetry.execute([:finch, :connect, :stop], %{duration: one_us_native * 20}, %{})
      :telemetry.execute([:finch, :send, :stop], %{duration: one_us_native * 30}, %{})
      :telemetry.execute([:finch, :recv, :stop], %{duration: one_us_native * 40}, %{})

      result = Timing.collect(ref)

      assert result.queue_us == 10
      assert result.connect_us == 20
      assert result.send_us == 30
      assert result.recv_us == 40
      assert result.idle_time_us == 2
      assert result.reused_connection? == false
    end
  end

  describe "duration conversion" do
    test "native time units are converted to microseconds" do
      one_us_native = System.convert_time_unit(1, :microsecond, :native)

      ref = Timing.start_capture()
      :telemetry.execute([:finch, :send, :stop], %{duration: one_us_native}, %{})

      result = Timing.collect(ref)

      assert result.send_us == 1
    end
  end

  describe "reused_connection?" do
    test "defaults to false" do
      ref = Timing.start_capture()
      result = Timing.collect(ref)

      assert result.reused_connection? == false
    end

    test "set to true when [:finch, :reused_connection] fires" do
      ref = Timing.start_capture()
      :telemetry.execute([:finch, :reused_connection], %{}, %{})

      result = Timing.collect(ref)

      assert result.reused_connection? == true
    end
  end

  describe "cleanup" do
    test "process dictionary entries for the ref are removed after collect" do
      one_us_native = System.convert_time_unit(1, :microsecond, :native)

      ref = Timing.start_capture()

      :telemetry.execute([:finch, :queue, :stop], %{duration: one_us_native}, %{})
      :telemetry.execute([:finch, :connect, :stop], %{duration: one_us_native}, %{})
      :telemetry.execute([:finch, :send, :stop], %{duration: one_us_native}, %{})
      :telemetry.execute([:finch, :recv, :stop], %{duration: one_us_native}, %{})
      :telemetry.execute([:finch, :reused_connection], %{}, %{})

      _result = Timing.collect(ref)

      # The timing ref itself should be removed
      assert Process.get(:philter_timing_ref) == nil

      # All event entries for this ref should be removed
      assert Process.get({ref, [:finch, :queue, :stop]}) == nil
      assert Process.get({ref, [:finch, :connect, :stop]}) == nil
      assert Process.get({ref, [:finch, :send, :stop]}) == nil
      assert Process.get({ref, [:finch, :recv, :stop]}) == nil
      assert Process.get({ref, [:finch, :reused_connection]}) == nil
    end
  end

  describe "mutual exclusivity of connect vs reused_connection" do
    test "reused_connection means connect_us is nil; connect means reused_connection? is false" do
      one_us_native = System.convert_time_unit(1, :microsecond, :native)

      # Case 1: reused_connection fires, no connect event
      ref1 = Timing.start_capture()
      :telemetry.execute([:finch, :reused_connection], %{}, %{})
      result1 = Timing.collect(ref1)

      assert result1.reused_connection? == true
      assert result1.connect_us == nil

      # Case 2: connect fires, no reused_connection event
      ref2 = Timing.start_capture()
      :telemetry.execute([:finch, :connect, :stop], %{duration: one_us_native * 5}, %{})
      result2 = Timing.collect(ref2)

      assert result2.reused_connection? == false
      assert result2.connect_us == 5
    end
  end

  describe "idle_time_us" do
    test "populated from [:finch, :queue, :stop] measurements" do
      one_us_native = System.convert_time_unit(1, :microsecond, :native)

      ref = Timing.start_capture()

      :telemetry.execute(
        [:finch, :queue, :stop],
        %{duration: one_us_native * 10, idle_time: one_us_native * 7},
        %{}
      )

      result = Timing.collect(ref)

      assert result.idle_time_us == 7
    end

    test "nil when queue event does not carry idle_time" do
      one_us_native = System.convert_time_unit(1, :microsecond, :native)

      ref = Timing.start_capture()
      :telemetry.execute([:finch, :queue, :stop], %{duration: one_us_native * 10}, %{})

      result = Timing.collect(ref)

      assert result.queue_us == 10
      assert result.idle_time_us == nil
    end
  end

  describe "no events fired" do
    test "collect returns all-nil phase fields and reused_connection?: false" do
      ref = Timing.start_capture()
      result = Timing.collect(ref)

      assert result.queue_us == nil
      assert result.connect_us == nil
      assert result.send_us == nil
      assert result.recv_us == nil
      assert result.idle_time_us == nil
      assert result.reused_connection? == false
    end
  end
end

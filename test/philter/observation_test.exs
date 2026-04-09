defmodule Philter.ObservationTest do
  use ExUnit.Case, async: true

  alias Philter.Observation

  describe "new/0" do
    test "initializes with empty state" do
      obs = Observation.new()
      assert obs.size == 0
      assert obs.preview == <<>>
      assert obs.accumulate? == false
      assert obs.accumulated_body == nil
    end
  end

  describe "new/1 with options" do
    test "enables accumulation when specified" do
      obs = Observation.new(accumulate?: true)
      assert obs.accumulate? == true
      assert obs.accumulated_body == []
    end

    test "sets max_size" do
      obs = Observation.new(max_size: 500_000)
      assert obs.max_size == 500_000
    end

    test "defaults max_size to 1MB" do
      obs = Observation.new()
      assert obs.max_size == 1_048_576
    end
  end

  describe "update/2" do
    test "increments size" do
      obs =
        Observation.new()
        |> Observation.update("hello")
        |> Observation.update("world")

      assert obs.size == 10
    end

    test "captures preview up to 64KB" do
      obs =
        Observation.new()
        |> Observation.update("hello")
        |> Observation.update(" world")

      assert obs.preview == "hello world"
    end

    test "stops capturing preview after 64KB" do
      obs = Observation.new()

      # Fill up preview
      chunk = :crypto.strong_rand_bytes(64 * 1024)
      obs = Observation.update(obs, chunk)

      # Additional data should not extend preview
      obs = Observation.update(obs, "extra")
      assert byte_size(obs.preview) == 64 * 1024
      assert obs.size == 64 * 1024 + 5
    end
  end

  describe "finalize/1" do
    test "computes correct SHA256 hash" do
      obs =
        Observation.new()
        |> Observation.update("hello world")
        |> Observation.finalize()

      expected_hash = :crypto.hash(:sha256, "hello world") |> Base.encode16(case: :lower)
      assert obs.hash == expected_hash
    end

    test "returns complete observation data" do
      obs =
        Observation.new()
        |> Observation.update("test data")
        |> Observation.finalize()

      assert Map.has_key?(obs, :hash)
      assert Map.has_key?(obs, :preview)
      assert Map.has_key?(obs, :size)
      assert Map.has_key?(obs, :body)
    end

    test "hash is correct for multi-chunk data" do
      data = "chunk1chunk2chunk3"

      obs =
        Observation.new()
        |> Observation.update("chunk1")
        |> Observation.update("chunk2")
        |> Observation.update("chunk3")
        |> Observation.finalize()

      expected_hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
      assert obs.hash == expected_hash
    end

    test "returns body as nil when not accumulating" do
      obs =
        Observation.new()
        |> Observation.update("test data")
        |> Observation.finalize()

      assert obs.body == nil
    end

    test "returns accumulated body when accumulating" do
      obs =
        Observation.new(accumulate?: true)
        |> Observation.update("hello ")
        |> Observation.update("world")
        |> Observation.finalize()

      assert obs.body == "hello world"
    end
  end

  describe "body accumulation" do
    test "accumulates chunks when enabled" do
      obs =
        Observation.new(accumulate?: true)
        |> Observation.update("chunk1")
        |> Observation.update("chunk2")

      assert obs.accumulated_body != nil
      assert obs.exceeded_threshold? == false
    end

    test "discards body when threshold exceeded" do
      obs =
        Observation.new(accumulate?: true, max_size: 10)
        # 5 bytes, under threshold
        |> Observation.update("12345")
        # 10 bytes total, still ok
        |> Observation.update("67890")
        # 15 bytes, over threshold
        |> Observation.update("extra")

      assert obs.exceeded_threshold? == true
      assert obs.accumulated_body == nil
    end

    test "finalize returns nil body when threshold exceeded" do
      obs =
        Observation.new(accumulate?: true, max_size: 10)
        |> Observation.update("this is way too long")
        |> Observation.finalize()

      assert obs.body == nil
      # Hash should still be computed
      assert obs.hash != nil
      assert obs.size == 20
    end

    test "hash is correct even when body discarded" do
      data = "this is a test of discarding accumulated body"

      obs =
        Observation.new(accumulate?: true, max_size: 10)
        |> Observation.update(data)
        |> Observation.finalize()

      expected_hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
      assert obs.hash == expected_hash
      assert obs.body == nil
    end

    test "stays discarded once threshold exceeded" do
      obs =
        Observation.new(accumulate?: true, max_size: 10)
        # Exceeds threshold
        |> Observation.update("12345678901")
        # Should stay discarded
        |> Observation.update("more data")

      assert obs.exceeded_threshold? == true
      assert obs.accumulated_body == nil
    end
  end
end

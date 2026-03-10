defmodule Philter.ObserverTest do
  use ExUnit.Case, async: true

  alias Philter.Observer

  defp default_config do
    %{
      persistable_content_types: ["application/json", "text/plain"],
      max_payload_size: 1_048_576
    }
  end

  describe "start_link/1" do
    test "returns {:ok, pid} where pid is alive" do
      {:ok, pid} = Observer.start_link(config: default_config())
      assert Process.alive?(pid)
    end
  end

  describe "request observation" do
    test "request chunks accumulate correctly" do
      {:ok, pid} =
        Observer.start_link(
          config: default_config(),
          req_accumulate?: true
        )

      Observer.request_chunk(pid, "hello ")
      Observer.request_chunk(pid, "world")

      result = Observer.finalize(pid)

      expected_hash =
        :crypto.hash(:sha256, "hello world")
        |> Base.encode16(case: :lower)

      assert %{
               hash: ^expected_hash,
               size: 11,
               body: "hello world"
             } = result.request

      assert is_binary(result.request.preview)
      assert result.request.preview == "hello world"
    end
  end

  describe "response observation" do
    test "response chunks accumulate when content-type is persistable" do
      {:ok, pid} = Observer.start_link(config: default_config())

      Observer.response_started(pid, [{"content-type", "application/json"}])
      Observer.response_chunk(pid, ~s({"key":))
      Observer.response_chunk(pid, ~s("value"}))

      result = Observer.finalize(pid)

      expected_hash =
        :crypto.hash(:sha256, ~s({"key":"value"}))
        |> Base.encode16(case: :lower)

      assert %{
               hash: ^expected_hash,
               size: 15,
               body: ~s({"key":"value"})
             } = result.response
    end

    test "response chunks do NOT accumulate body for non-persistable content types" do
      {:ok, pid} = Observer.start_link(config: default_config())

      Observer.response_started(pid, [{"content-type", "image/png"}])
      Observer.response_chunk(pid, "binary-data")

      result = Observer.finalize(pid)

      assert result.response.body == nil
      assert result.response.size == 11
    end

    test "handles Content-Type header with capital letters" do
      {:ok, pid} = Observer.start_link(config: default_config())

      Observer.response_started(pid, [{"Content-Type", "text/plain"}])
      Observer.response_chunk(pid, "plain text")

      result = Observer.finalize(pid)

      assert result.response.body == "plain text"
    end
  end

  describe "finalize/1" do
    test "returns request and response maps and process exits" do
      {:ok, pid} =
        Observer.start_link(
          config: default_config(),
          req_accumulate?: true
        )

      Observer.request_chunk(pid, "req-body")
      Observer.response_started(pid, [{"content-type", "text/plain"}])
      Observer.response_chunk(pid, "resp-body")

      result = Observer.finalize(pid)

      assert %{request: %{}, response: %{}} = result

      # Verify both observations have correct keys
      for key <- [:hash, :size, :preview, :body, :duration_us, :time_to_first_byte_us] do
        assert Map.has_key?(result.request, key), "request missing #{key}"
        assert Map.has_key?(result.response, key), "response missing #{key}"
      end

      # Process should exit after finalize
      Process.sleep(10)
      refute Process.alive?(pid)
    end
  end

  describe "hashing" do
    test "multiple chunks produce correct SHA256 hash" do
      chunks = ["alpha", "bravo", "charlie", "delta"]
      combined = Enum.join(chunks)

      {:ok, pid} =
        Observer.start_link(
          config: default_config(),
          req_accumulate?: true
        )

      Enum.each(chunks, &Observer.request_chunk(pid, &1))

      result = Observer.finalize(pid)

      expected_hash =
        :crypto.hash(:sha256, combined)
        |> Base.encode16(case: :lower)

      assert result.request.hash == expected_hash
      assert result.request.size == byte_size(combined)
    end
  end

  describe "size limits" do
    test "large bodies have preview capped at 64KB" do
      preview_size = 64 * 1024

      {:ok, pid} =
        Observer.start_link(
          config: default_config(),
          req_accumulate?: true
        )

      # Send 100KB in 10KB chunks
      chunk = :crypto.strong_rand_bytes(10 * 1024)

      for _ <- 1..10 do
        Observer.request_chunk(pid, chunk)
      end

      result = Observer.finalize(pid)

      assert result.request.size == 100 * 1024
      assert byte_size(result.request.preview) == preview_size
    end

    test "accumulation threshold (max_size) discards body when exceeded" do
      config = %{default_config() | max_payload_size: 50}

      {:ok, pid} =
        Observer.start_link(
          config: config,
          req_accumulate?: true
        )

      # Send 100 bytes — exceeds the 50-byte threshold
      Observer.request_chunk(pid, String.duplicate("x", 100))

      result = Observer.finalize(pid)

      assert result.request.body == nil
      assert result.request.size == 100
      # Hash should still be computed
      assert is_binary(result.request.hash)
    end
  end

  describe "process lifecycle" do
    test "observer exits when caller crashes (linked process)" do
      test_pid = self()

      # Spawn an intermediate process that starts the observer then
      # reports the observer pid back to us before dying.
      spawner =
        spawn(fn ->
          {:ok, observer_pid} =
            Observer.start_link(config: default_config())

          send(test_pid, {:observer_pid, observer_pid})

          # Keep alive until told to die
          receive do
            :die -> :ok
          end
        end)

      observer_pid =
        receive do
          {:observer_pid, pid} -> pid
        end

      assert Process.alive?(observer_pid)

      # Kill the parent (spawner) — observer should die too
      Process.exit(spawner, :kill)
      Process.sleep(50)

      refute Process.alive?(observer_pid)
    end
  end

  describe "edge cases" do
    test "empty body finalize returns sensible defaults" do
      {:ok, pid} = Observer.start_link(config: default_config())

      result = Observer.finalize(pid)

      empty_hash =
        :crypto.hash(:sha256, "")
        |> Base.encode16(case: :lower)

      assert %{
               hash: ^empty_hash,
               size: 0,
               body: nil,
               preview: "",
               time_to_first_byte_us: nil
             } = result.request

      assert %{
               hash: ^empty_hash,
               size: 0,
               body: nil,
               preview: "",
               time_to_first_byte_us: nil
             } = result.response
    end
  end
end

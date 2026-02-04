defmodule Weir.BodyStreamTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Weir.BodyStream

  describe "from_conn/2" do
    test "reads small body" do
      body = "hello world"
      conn = conn(:post, "/", body)

      {:stream, stream} = BodyStream.from_conn(conn)
      chunks = Enum.to_list(stream)

      assert IO.iodata_to_binary(chunks) == body
    end

    test "reads large body in multiple chunks" do
      body = String.duplicate("a", 200_000)
      conn = conn(:post, "/", body)

      {:stream, stream} = BodyStream.from_conn(conn, chunk_size: 64_000)
      chunks = Enum.to_list(stream)

      assert length(chunks) > 1
      assert IO.iodata_to_binary(chunks) == body
    end

    test "calls on_chunk for each chunk" do
      body = String.duplicate("b", 150_000)
      conn = conn(:post, "/", body)

      parent = self()
      on_chunk = fn chunk -> send(parent, {:chunk, byte_size(chunk)}) end

      {:stream, stream} = BodyStream.from_conn(conn, on_chunk: on_chunk, chunk_size: 64_000)
      Stream.run(stream)

      # Should receive multiple chunks
      assert_receive {:chunk, size1}
      assert_receive {:chunk, _size2}
      assert size1 > 0
    end

    test "handles empty body" do
      conn = conn(:post, "/", "")

      {:stream, stream} = BodyStream.from_conn(conn)
      chunks = Enum.to_list(stream)

      assert chunks == [] or chunks == [""]
    end
  end

  describe "from_conn_with_observation/2" do
    test "observes chunks and computes hash" do
      body = "test body content"
      conn = conn(:post, "/", body)

      {{:stream, stream}, obs_agent} = BodyStream.from_conn_with_observation(conn)
      Enum.to_list(stream)  # Consume the stream

      observation = BodyStream.finalize_observation(obs_agent)

      expected_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      assert observation.hash == expected_hash
      assert observation.size == byte_size(body)
      assert observation.preview == body
    end

    test "captures preview for large body" do
      # Create 100KB body
      body = String.duplicate("x", 100_000)
      conn = conn(:post, "/", body)

      {{:stream, stream}, obs_agent} = BodyStream.from_conn_with_observation(conn)
      Enum.to_list(stream)

      observation = BodyStream.finalize_observation(obs_agent)

      assert observation.size == 100_000
      assert byte_size(observation.preview) == 64 * 1024  # Preview capped at 64KB
    end
  end
end

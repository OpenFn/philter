defmodule Philter.BodyStreamTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Philter.BodyStream

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
end

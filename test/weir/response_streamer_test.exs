defmodule Weir.ResponseStreamerTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Weir.ResponseStreamer

  setup do
    conn = conn(:get, "/test")
    {:ok, obs_agent} = Agent.start_link(fn -> Weir.Observation.new() end)
    {:ok, conn: conn, obs_agent: obs_agent}
  end

  describe "new/2" do
    test "initializes state with conn and agent", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)

      assert state.conn == conn
      assert state.obs_agent == obs_agent
      assert state.status == nil
      assert state.headers_sent == false
      assert state.error == nil
    end
  end

  describe "handle_message/2 with :status" do
    test "stores status code", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)

      {:cont, state} = ResponseStreamer.handle_message({:status, 200}, state)

      assert state.status == 200
    end

    test "handles various status codes", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)

      {:cont, state} = ResponseStreamer.handle_message({:status, 404}, state)
      assert state.status == 404

      state = ResponseStreamer.new(conn, obs_agent)
      {:cont, state} = ResponseStreamer.handle_message({:status, 500}, state)
      assert state.status == 500
    end
  end

  describe "handle_message/2 with :headers" do
    test "sends chunked response with filtered headers", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)
      |> then(&%{&1 | status: 200})

      headers = [
        {"Content-Type", "application/json"},
        {"X-Custom", "value"},
        {"Transfer-Encoding", "chunked"},  # Should be filtered
        {"Connection", "keep-alive"}        # Should be filtered
      ]

      {:cont, state} = ResponseStreamer.handle_message({:headers, headers}, state)

      assert state.headers_sent == true
      assert state.conn.status == 200

      # Custom headers should be forwarded
      assert Plug.Conn.get_resp_header(state.conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_resp_header(state.conn, "x-custom") == ["value"]

      # Hop-by-hop headers should be filtered
      assert Plug.Conn.get_resp_header(state.conn, "transfer-encoding") == []
      assert Plug.Conn.get_resp_header(state.conn, "connection") == []
    end

    test "filters content-length header", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)
      |> then(&%{&1 | status: 200})

      headers = [{"Content-Length", "1234"}, {"X-Custom", "value"}]

      {:cont, state} = ResponseStreamer.handle_message({:headers, headers}, state)

      assert Plug.Conn.get_resp_header(state.conn, "content-length") == []
      assert Plug.Conn.get_resp_header(state.conn, "x-custom") == ["value"]
    end
  end

  describe "handle_message/2 with :data" do
    test "updates observation with chunk data", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)
      |> then(&%{&1 | status: 200})

      # Send headers first to enable chunked response
      {:cont, state} = ResponseStreamer.handle_message({:headers, []}, state)

      # Send data chunk
      {:cont, _state} = ResponseStreamer.handle_message({:data, "hello"}, state)

      # Check observation was updated
      obs = Agent.get(obs_agent, & &1)
      assert obs.size == 5
    end

    test "accumulates multiple chunks in observation", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)
      |> then(&%{&1 | status: 200})

      {:cont, state} = ResponseStreamer.handle_message({:headers, []}, state)
      {:cont, state} = ResponseStreamer.handle_message({:data, "hello"}, state)
      {:cont, _state} = ResponseStreamer.handle_message({:data, " world"}, state)

      obs = Agent.get(obs_agent, & &1)
      assert obs.size == 11
      assert obs.preview == "hello world"
    end

    test "returns :cont on successful chunk", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)
      |> then(&%{&1 | status: 200})

      {:cont, state} = ResponseStreamer.handle_message({:headers, []}, state)

      result = ResponseStreamer.handle_message({:data, "test"}, state)

      assert {:cont, _state} = result
    end
  end

  describe "handle_message/2 with :trailers" do
    test "passes through without modification", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)

      {:cont, new_state} = ResponseStreamer.handle_message({:trailers, [{"x-trailer", "value"}]}, state)

      assert new_state == state
    end
  end

  describe "get_conn/1" do
    test "returns the conn from state", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)

      assert ResponseStreamer.get_conn(state) == conn
    end
  end

  describe "get_error/1" do
    test "returns nil when no error", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)

      assert ResponseStreamer.get_error(state) == nil
    end

    test "returns error when set", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)
      state = %{state | error: :closed}

      assert ResponseStreamer.get_error(state) == :closed
    end
  end

  describe "has_error?/1" do
    test "returns false when no error", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)

      assert ResponseStreamer.has_error?(state) == false
    end

    test "returns true when error is set", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)
      state = %{state | error: :closed}

      assert ResponseStreamer.has_error?(state) == true
    end
  end

  describe "integration: full response flow" do
    test "handles complete response sequence", %{conn: conn, obs_agent: obs_agent} do
      state = ResponseStreamer.new(conn, obs_agent)

      # Status
      {:cont, state} = ResponseStreamer.handle_message({:status, 200}, state)
      assert state.status == 200

      # Headers
      headers = [{"Content-Type", "text/plain"}, {"X-Request-Id", "123"}]
      {:cont, state} = ResponseStreamer.handle_message({:headers, headers}, state)
      assert state.headers_sent == true

      # Data chunks
      {:cont, state} = ResponseStreamer.handle_message({:data, "Hello, "}, state)
      {:cont, state} = ResponseStreamer.handle_message({:data, "World!"}, state)

      # Trailers
      {:cont, state} = ResponseStreamer.handle_message({:trailers, []}, state)

      # Verify final state
      assert state.error == nil
      assert state.conn.status == 200

      # Verify observation
      obs = Agent.get(obs_agent, &Weir.Observation.finalize/1)
      expected_hash = :crypto.hash(:sha256, "Hello, World!") |> Base.encode16(case: :lower)
      assert obs.hash == expected_hash
      assert obs.size == 13
      assert obs.preview == "Hello, World!"
    end
  end
end

defmodule WeirTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  defmodule TestHandler do
    use Weir.Handler

    @impl true
    def handle_request_started(metadata, state) do
      send(state[:test_pid], {:request_started, metadata})
      {:ok, state}
    end

    @impl true
    def handle_response_started(metadata, state) do
      send(state[:test_pid], {:response_started, metadata})
      {:ok, state}
    end

    @impl true
    def handle_response_finished(result, state) do
      send(state[:test_pid], {:response_finished, result})
      {:ok, state}
    end
  end

  defmodule RejectingHandler do
    use Weir.Handler

    @impl true
    def handle_request_started(_metadata, state) do
      {:reject, 413, "Payload Too Large", state}
    end

    @impl true
    def handle_response_finished(_result, state), do: {:ok, state}
  end

  defmodule TrackingRejectHandler do
    use Weir.Handler

    @impl true
    def handle_request_started(_metadata, state) do
      send(state[:test_pid], :request_rejected)
      {:reject, 403, "Forbidden", state}
    end

    @impl true
    def handle_response_finished(_result, state) do
      send(state[:test_pid], :response_finished_called)
      {:ok, state}
    end
  end

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, upstream: "http://localhost:#{bypass.port}"}
  end

  describe "proxy/2" do
    test "proxies GET request and returns observations", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/test", fn conn ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, ~s({"status": "ok"}))
      end)

      conn =
        conn(:get, "/test")
        |> Weir.proxy(upstream: upstream, finch_name: Weir.TestFinch)

      assert conn.status == 200
      assert conn.resp_body =~ "status"

      req_obs = conn.private[:weir_request_observation]
      resp_obs = conn.private[:weir_response_observation]

      assert req_obs.size == 0
      assert resp_obs.size > 0
      assert resp_obs.hash != nil
    end

    test "proxies POST request with body accumulation", %{bypass: bypass, upstream: upstream} do
      request_body = ~s({"name": "test"})

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = read_body(conn)
        assert body == request_body

        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(201, ~s({"id": 123}))
      end)

      conn =
        conn(:post, "/api", request_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-length", "#{byte_size(request_body)}")
        |> Weir.proxy(
          upstream: upstream,
          finch_name: Weir.TestFinch,
          persistable_content_types: ["application/json"]
        )

      assert conn.status == 201

      req_obs = conn.private[:weir_request_observation]
      resp_obs = conn.private[:weir_response_observation]

      # Request body should be accumulated (JSON under threshold)
      assert req_obs.body == request_body
      assert req_obs.size == byte_size(request_body)

      # Response body should be accumulated (JSON under threshold)
      assert resp_obs.body == ~s({"id": 123})
    end

    test "does not accumulate binary content types", %{bypass: bypass, upstream: upstream} do
      binary_body = :crypto.strong_rand_bytes(1000)

      Bypass.expect(bypass, "POST", "/upload", fn conn ->
        {:ok, _body, conn} = read_body(conn)

        conn
        |> put_resp_header("content-type", "image/png")
        |> send_resp(200, binary_body)
      end)

      conn =
        conn(:post, "/upload", binary_body)
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-length", "#{byte_size(binary_body)}")
        |> Weir.proxy(
          upstream: upstream,
          finch_name: Weir.TestFinch,
          persistable_content_types: ["application/json", "text/*"]
        )

      assert conn.status == 200

      req_obs = conn.private[:weir_request_observation]
      resp_obs = conn.private[:weir_response_observation]

      # Binary content should not be accumulated
      assert req_obs.body == nil
      assert resp_obs.body == nil

      # But hash and preview should still exist
      assert req_obs.hash != nil
      assert resp_obs.hash != nil
      assert req_obs.preview != nil
    end

    test "discards accumulated body when threshold exceeded", %{
      bypass: bypass,
      upstream: upstream
    } do
      # Create response larger than 1KB threshold
      large_json = ~s({"data": "#{String.duplicate("x", 2000)}"})

      Bypass.expect(bypass, "GET", "/large", fn conn ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, large_json)
      end)

      conn =
        conn(:get, "/large")
        |> Weir.proxy(
          upstream: upstream,
          finch_name: Weir.TestFinch,
          max_payload_size: 1000,
          persistable_content_types: ["application/json"]
        )

      assert conn.status == 200

      resp_obs = conn.private[:weir_response_observation]

      # Body should be nil because it exceeded threshold
      assert resp_obs.body == nil
      # But hash should still be computed
      assert resp_obs.hash != nil
      assert resp_obs.size == byte_size(large_json)
      # Preview should exist (up to 64KB)
      assert resp_obs.preview != nil
    end

    test "invokes handler callbacks", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/observed", fn conn ->
        conn
        |> put_resp_header("content-type", "text/plain")
        |> send_resp(200, "hello")
      end)

      conn =
        conn(:get, "/observed")
        |> Weir.proxy(
          upstream: upstream,
          finch_name: Weir.TestFinch,
          handler: {TestHandler, %{test_pid: self()}},
          request_id: "test-123"
        )

      assert conn.status == 200

      # Should receive request_started callback
      assert_receive {:request_started, req_meta}
      assert req_meta.request_id == "test-123"
      assert req_meta.method == "GET"
      assert req_meta.upstream_url =~ "/observed"

      # Should receive response_started callback
      assert_receive {:response_started, resp_meta}
      assert resp_meta.request_id == "test-123"
      assert resp_meta.status == 200

      # Should receive response_finished callback
      assert_receive {:response_finished, result}
      assert result.request_id == "test-123"
      assert result.error == nil
      assert result.request_observation.hash != nil
      assert result.response_observation.hash != nil
    end

    test "injects x-request-id header into upstream request", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/rid", fn conn ->
        [request_id] = Plug.Conn.get_req_header(conn, "x-request-id")
        assert byte_size(request_id) > 0
        Plug.Conn.send_resp(conn, 200, request_id)
      end)

      conn =
        conn(:get, "/rid")
        |> Weir.proxy(upstream: upstream, finch_name: Weir.TestFinch)

      assert conn.status == 200
      assert byte_size(conn.resp_body) > 0
    end

    test "propagates caller-supplied request_id as x-request-id header", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/rid", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-request-id") == ["custom-id-42"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/rid")
        |> Weir.proxy(
          upstream: upstream,
          finch_name: Weir.TestFinch,
          request_id: "custom-id-42"
        )

      assert conn.status == 200
    end

    test "invokes handler on error with error info", %{upstream: _upstream} do
      # Connect to non-existent server
      conn =
        conn(:get, "/test")
        |> Weir.proxy(
          upstream: "http://localhost:59999",
          finch_name: Weir.TestFinch,
          handler: {TestHandler, %{test_pid: self()}},
          request_id: "error-test"
        )

      assert conn.status == 502
      assert conn.halted

      # Should still receive response_finished with error
      assert_receive {:response_finished, result}
      assert result.request_id == "error-test"
      assert result.error != nil
      assert result.status == nil
    end

    test "rejects proxy with handler-controlled status and body", %{upstream: upstream} do
      conn =
        conn(:get, "/test")
        |> Weir.proxy(
          upstream: upstream,
          finch_name: Weir.TestFinch,
          handler: {RejectingHandler, %{}}
        )

      assert conn.status == 413
      assert conn.resp_body == "Payload Too Large"
    end

    test "handle_response_finished is not called when request is rejected", %{
      upstream: upstream
    } do
      conn =
        conn(:get, "/test")
        |> Weir.proxy(
          upstream: upstream,
          finch_name: Weir.TestFinch,
          handler: {TrackingRejectHandler, %{test_pid: self()}}
        )

      assert conn.status == 403
      assert_receive :request_rejected
      refute_receive :response_finished_called, 100
    end

    test "time_to_first_byte_us is relative to request start", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/ttfb", fn conn ->
        # Small delay to ensure TTFB > 0
        Process.sleep(10)

        conn
        |> put_resp_header("content-type", "text/plain")
        |> send_resp(200, "hello")
      end)

      conn =
        conn(:get, "/ttfb")
        |> Weir.proxy(
          upstream: upstream,
          finch_name: Weir.TestFinch,
          handler: {TestHandler, %{test_pid: self()}},
          request_id: "ttfb-test"
        )

      assert conn.status == 200

      assert_receive {:response_started, resp_meta}
      assert resp_meta.time_to_first_byte_us > 0
      # If it were absolute monotonic time, it would be billions of microseconds
      assert resp_meta.time_to_first_byte_us < 5_000_000
    end
  end

  describe "proxy/2 path override" do
    test "uses string path override", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/api/v2", fn conn ->
        send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/channels/some-id/api/v2")
        |> Weir.proxy(upstream: upstream, finch_name: Weir.TestFinch, path: "/api/v2")

      assert conn.status == 200
      assert conn.resp_body =~ "ok"
    end

    test "uses function path override", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/prefix/original", fn conn ->
        send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/original")
        |> Weir.proxy(
          upstream: upstream,
          finch_name: Weir.TestFinch,
          path: fn conn -> "/prefix" <> conn.request_path end
        )

      assert conn.status == 200
    end

    test "preserves query string with path override", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/override", fn conn ->
        assert conn.query_string == "foo=bar"
        send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/original?foo=bar")
        |> Weir.proxy(upstream: upstream, finch_name: Weir.TestFinch, path: "/override")

      assert conn.status == 200
    end

    test "defaults to conn.request_path when no path option", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/default-path", fn conn ->
        send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/default-path")
        |> Weir.proxy(upstream: upstream, finch_name: Weir.TestFinch)

      assert conn.status == 200
    end
  end

  describe "proxy/2 timeout handling" do
    test "returns 504 on timeout" do
      # Start a TCP server that accepts but never responds
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen_socket)

      spawn(fn ->
        {:ok, _client} = :gen_tcp.accept(listen_socket)
        Process.sleep(10_000)
      end)

      conn =
        conn(:get, "/timeout")
        |> Weir.proxy(
          upstream: "http://localhost:#{port}",
          finch_name: Weir.TestFinch,
          receive_timeout: 100
        )

      :gen_tcp.close(listen_socket)

      assert conn.status == 504
      assert conn.halted
    end
  end
end

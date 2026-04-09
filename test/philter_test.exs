defmodule PhilterTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  defmodule TestHandler do
    use Philter.Handler

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
    use Philter.Handler

    @impl true
    def handle_request_started(_metadata, state) do
      {:reject, 413, "Payload Too Large", state}
    end

    @impl true
    def handle_response_finished(_result, state), do: {:ok, state}
  end

  defmodule TrackingRejectHandler do
    use Philter.Handler

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
        |> Philter.proxy(upstream: upstream, finch_name: Philter.TestFinch)

      assert conn.status == 200
      assert conn.resp_body =~ "status"

      req_obs = conn.private[:philter_request_observation]
      resp_obs = conn.private[:philter_response_observation]

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
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          persistable_content_types: ["application/json"]
        )

      assert conn.status == 201

      req_obs = conn.private[:philter_request_observation]
      resp_obs = conn.private[:philter_response_observation]

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
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          persistable_content_types: ["application/json", "text/*"]
        )

      assert conn.status == 200

      req_obs = conn.private[:philter_request_observation]
      resp_obs = conn.private[:philter_response_observation]

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
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          max_payload_size: 1000,
          persistable_content_types: ["application/json"]
        )

      assert conn.status == 200

      resp_obs = conn.private[:philter_response_observation]

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
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          handler: {TestHandler, %{test_pid: self()}}
        )

      assert conn.status == 200

      # Should receive request_started callback
      assert_receive {:request_started, req_meta}
      assert req_meta.method == "GET"
      assert req_meta.upstream_url =~ "/observed"

      # Should receive response_started callback
      assert_receive {:response_started, resp_meta}
      assert resp_meta.status == 200

      # Should receive response_finished callback
      assert_receive {:response_finished, result}
      assert result.error == nil
      assert result.request_observation.hash != nil
      assert result.response_observation.hash != nil
      assert is_integer(result.timing.total_us) and result.timing.total_us > 0
    end

    test "uses caller-supplied headers when provided", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "POST", "/api", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        # Caller-supplied headers bypass hop-by-hop filtering (host is still rewritten)
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:post, "/api", "")
        # These conn headers should be ignored when :headers is provided
        |> put_req_header("x-should-not-appear", "ignored")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          headers: [
            {"authorization", "Bearer test"},
            {"content-type", "application/json"}
          ]
        )

      assert conn.status == 200
    end

    test "filters conn.req_headers when no headers option provided", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/headers", fn conn ->
        # Custom headers should be forwarded (lowercased)
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["value"]
        # Hop-by-hop headers should be stripped
        assert Plug.Conn.get_req_header(conn, "connection") == []
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/headers")
        |> put_req_header("x-custom", "value")
        |> put_req_header("connection", "keep-alive")
        |> Philter.proxy(upstream: upstream, finch_name: Philter.TestFinch)

      assert conn.status == 200
    end

    test "rewrites host header to match upstream", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/host-check", fn conn ->
        [host] = Plug.Conn.get_req_header(conn, "host")
        assert host == "localhost:#{bypass.port}"
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/host-check")
        |> Map.put(:host, "original-host.example.com")
        |> Philter.proxy(upstream: upstream, finch_name: Philter.TestFinch)

      assert conn.status == 200
    end

    test "preserves caller-supplied host header when explicitly provided", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/host-check", fn conn ->
        [host] = Plug.Conn.get_req_header(conn, "host")
        assert host == "custom-host.example.com"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/host-check")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          headers: [
            {"host", "custom-host.example.com"},
            {"authorization", "Bearer tok"}
          ]
        )

      assert conn.status == 200
    end

    test "preserves title-case Host header without duplication", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/host-check", fn conn ->
        hosts = Plug.Conn.get_req_header(conn, "host")
        assert hosts == ["custom-host.example.com"]
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/host-check")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          headers: [
            {"Host", "custom-host.example.com"},
            {"authorization", "Bearer tok"}
          ]
        )

      assert conn.status == 200
    end

    test "uses upstream host when caller-supplied headers omit host", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/host-check", fn conn ->
        [host] = Plug.Conn.get_req_header(conn, "host")
        assert host == "localhost:#{bypass.port}"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/host-check")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          headers: [
            {"authorization", "Bearer tok"}
          ]
        )

      assert conn.status == 200
    end

    test "passes caller-supplied headers to handle_request_started metadata", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/meta", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      custom_headers = [{"authorization", "Bearer tok"}, {"x-custom", "val"}]

      _conn =
        conn(:get, "/meta")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          handler: {TestHandler, %{test_pid: self()}},
          headers: custom_headers
        )

      assert_receive {:request_started, req_meta}

      # Custom headers are present, plus upstream host added as default (no explicit host in caller headers)
      assert {"authorization", "Bearer tok"} in req_meta.headers
      assert {"x-custom", "val"} in req_meta.headers
      assert {"host", "localhost:" <> _} = List.keyfind(req_meta.headers, "host", 0)
    end

    test "invokes handler on error with error info", %{upstream: _upstream} do
      # Connect to non-existent server
      conn =
        conn(:get, "/test")
        |> Philter.proxy(
          upstream: "http://localhost:59999",
          finch_name: Philter.TestFinch,
          handler: {TestHandler, %{test_pid: self()}}
        )

      assert conn.status == 502
      assert conn.halted

      # Should still receive response_finished with error
      assert_receive {:response_finished, result}
      assert result.error != nil
      assert result.status == nil
      assert is_integer(result.timing.total_us) and result.timing.total_us > 0
    end

    test "rejects proxy with handler-controlled status and body", %{upstream: upstream} do
      conn =
        conn(:get, "/test")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
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
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
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
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          handler: {TestHandler, %{test_pid: self()}}
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
        |> Philter.proxy(upstream: upstream, finch_name: Philter.TestFinch, path: "/api/v2")

      assert conn.status == 200
      assert conn.resp_body =~ "ok"
    end

    test "uses function path override", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/prefix/original", fn conn ->
        send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/original")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
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
        |> Philter.proxy(upstream: upstream, finch_name: Philter.TestFinch, path: "/override")

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
        |> Philter.proxy(upstream: upstream, finch_name: Philter.TestFinch)

      assert conn.status == 200
    end
  end

  describe "proxy/2 strip_headers" do
    test "strip_headers removes a named header", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/strip", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["keep-me"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/strip")
        |> put_req_header("authorization", "Bearer secret")
        |> put_req_header("x-custom", "keep-me")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          strip_headers: ["authorization"]
        )

      assert conn.status == 200
    end

    test "strip_headers is case-insensitive", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/strip-case", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/strip-case")
        |> put_req_header("authorization", "Bearer secret")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          strip_headers: ["Authorization"]
        )

      assert conn.status == 200
    end

    test "strip_headers with non-existent header is a no-op", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/strip-noop", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["present"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/strip-noop")
        |> put_req_header("x-custom", "present")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          strip_headers: ["x-nonexistent"]
        )

      assert conn.status == 200
    end
  end

  describe "proxy/2 extra_headers" do
    test "extra_headers adds a new header", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/extra", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == ["1.2.3.4"]
        # Existing conn headers should still be present
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["original"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/extra")
        |> put_req_header("x-custom", "original")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          extra_headers: [{"x-forwarded-for", "1.2.3.4"}]
        )

      assert conn.status == 200
    end

    test "extra_headers replaces an existing header (case-insensitive)", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/extra-replace", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["replaced"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/extra-replace")
        |> put_req_header("x-custom", "original")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          extra_headers: [{"x-custom", "replaced"}]
        )

      assert conn.status == 200
    end

    test "extra_headers does not get filtered for hop-by-hop", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/extra-hop", fn conn ->
        assert Plug.Conn.get_req_header(conn, "connection") == ["keep-alive"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/extra-hop")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          extra_headers: [{"connection", "keep-alive"}]
        )

      assert conn.status == 200
    end
  end

  describe "proxy/2 strip_headers + extra_headers combined" do
    test "strip inbound auth, replace with service auth", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/combined", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer service-token"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/combined")
        |> put_req_header("authorization", "Bearer user-token")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          strip_headers: ["authorization"],
          extra_headers: [{"authorization", "Bearer service-token"}]
        )

      assert conn.status == 200
    end

    test "strip multiple, add multiple", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/multi-combined", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        assert Plug.Conn.get_req_header(conn, "cookie") == []
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["keep-me"]
        assert Plug.Conn.get_req_header(conn, "x-forwarded-for") == ["1.2.3.4"]
        assert Plug.Conn.get_req_header(conn, "x-request-id") == ["abc123"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/multi-combined")
        |> put_req_header("authorization", "Bearer secret")
        |> put_req_header("cookie", "session=abc")
        |> put_req_header("x-custom", "keep-me")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          strip_headers: ["authorization", "cookie"],
          extra_headers: [{"x-forwarded-for", "1.2.3.4"}, {"x-request-id", "abc123"}]
        )

      assert conn.status == 200
    end
  end

  describe "proxy/2 header option validation" do
    test ":headers + :extra_headers raises ArgumentError", %{upstream: upstream} do
      assert_raise ArgumentError,
                   ~r/:headers cannot be combined with :extra_headers or :strip_headers/,
                   fn ->
                     conn(:get, "/test")
                     |> Philter.proxy(
                       upstream: upstream,
                       finch_name: Philter.TestFinch,
                       headers: [{"authorization", "Bearer tok"}],
                       extra_headers: [{"x-extra", "val"}]
                     )
                   end
    end

    test ":headers + :strip_headers raises ArgumentError", %{upstream: upstream} do
      assert_raise ArgumentError,
                   ~r/:headers cannot be combined with :extra_headers or :strip_headers/,
                   fn ->
                     conn(:get, "/test")
                     |> Philter.proxy(
                       upstream: upstream,
                       finch_name: Philter.TestFinch,
                       headers: [{"authorization", "Bearer tok"}],
                       strip_headers: ["x-unwanted"]
                     )
                   end
    end

    test ":headers + both :extra_headers and :strip_headers raises ArgumentError", %{
      upstream: upstream
    } do
      assert_raise ArgumentError,
                   ~r/:headers cannot be combined with :extra_headers or :strip_headers/,
                   fn ->
                     conn(:get, "/test")
                     |> Philter.proxy(
                       upstream: upstream,
                       finch_name: Philter.TestFinch,
                       headers: [{"authorization", "Bearer tok"}],
                       extra_headers: [{"x-extra", "val"}],
                       strip_headers: ["x-unwanted"]
                     )
                   end
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
        |> Philter.proxy(
          upstream: "http://localhost:#{port}",
          finch_name: Philter.TestFinch,
          receive_timeout: 100
        )

      :gen_tcp.close(listen_socket)

      assert conn.status == 504
      assert conn.halted
    end
  end

  describe "proxy/2 timing" do
    test "without collect_timing, timing has total_us and nil phase fields", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/timing-default", fn conn ->
        conn
        |> put_resp_header("content-type", "text/plain")
        |> send_resp(200, "hello")
      end)

      conn =
        conn(:get, "/timing-default")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          handler: {TestHandler, %{test_pid: self()}}
        )

      assert conn.status == 200

      assert_receive {:response_finished, result}
      timing = result.timing

      assert is_integer(timing.total_us) and timing.total_us > 0
      assert timing.queue_us == nil
      assert timing.connect_us == nil
      assert timing.send_us == nil
      assert timing.recv_us == nil
      assert timing.idle_time_us == nil
      assert timing.reused_connection? == nil
    end

    test "with collect_timing: true, phase timing fields are populated", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/timing-collect", fn conn ->
        conn
        |> put_resp_header("content-type", "text/plain")
        |> send_resp(200, "hello")
      end)

      conn =
        conn(:get, "/timing-collect")
        |> Philter.proxy(
          upstream: upstream,
          finch_name: Philter.TestFinch,
          handler: {TestHandler, %{test_pid: self()}},
          collect_timing: true
        )

      assert conn.status == 200

      assert_receive {:response_finished, result}
      timing = result.timing

      assert is_integer(timing.total_us) and timing.total_us > 0
      assert is_integer(timing.queue_us) and timing.queue_us >= 0
      assert is_integer(timing.send_us) and timing.send_us >= 0
      assert is_integer(timing.recv_us) and timing.recv_us >= 0
      assert is_boolean(timing.reused_connection?)

      assert timing.idle_time_us == nil or
               (is_integer(timing.idle_time_us) and timing.idle_time_us >= 0)
    end

    test "error paths still get timing", %{upstream: _upstream} do
      conn =
        conn(:get, "/test")
        |> Philter.proxy(
          upstream: "http://localhost:59999",
          finch_name: Philter.TestFinch,
          handler: {TestHandler, %{test_pid: self()}}
        )

      assert conn.status == 502

      assert_receive {:response_finished, result}
      assert result.error != nil
      assert is_integer(result.timing.total_us) and result.timing.total_us > 0
    end
  end

  describe "logging" do
    test "default :debug level emits request start with method, URL, and host", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/log-test", fn conn ->
        send_resp(conn, 200, "ok")
      end)

      log =
        capture_log([level: :debug], fn ->
          conn(:get, "/log-test")
          |> Philter.proxy(upstream: upstream, finch_name: Philter.TestFinch)
        end)

      assert log =~ "Philter GET"
      assert log =~ "/log-test"
      assert log =~ "host=localhost:#{bypass.port}"
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

    test "error paths log at :error level", %{upstream: _upstream} do
      log =
        capture_log([level: :error], fn ->
          conn(:get, "/fail")
          |> Philter.proxy(
            upstream: "http://localhost:59999",
            finch_name: Philter.TestFinch
          )
        end)

      assert log =~ "Philter error 502"
      assert log =~ "upstream=http://localhost:59999/fail"
    end

    test "response complete log includes status, size, and duration", %{
      bypass: bypass,
      upstream: upstream
    } do
      Bypass.expect(bypass, "GET", "/complete", fn conn ->
        send_resp(conn, 200, "hello")
      end)

      log =
        capture_log([level: :debug], fn ->
          conn(:get, "/complete")
          |> Philter.proxy(upstream: upstream, finch_name: Philter.TestFinch)
        end)

      assert log =~ "Philter complete 200"
      assert log =~ "5B"
      assert log =~ ~r/\d+ms/
    end

    test "rejection is logged with method, URL, and status", %{upstream: upstream} do
      log =
        capture_log([level: :debug], fn ->
          conn(:get, "/rejected")
          |> Philter.proxy(
            upstream: upstream,
            finch_name: Philter.TestFinch,
            handler: {RejectingHandler, %{}}
          )
        end)

      assert log =~ "Philter rejected GET"
      assert log =~ "/rejected"
      assert log =~ "status=413"
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
end

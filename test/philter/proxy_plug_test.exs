defmodule Philter.ProxyPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Philter.ProxyPlug

  setup do
    bypass = Bypass.open()

    {:ok,
     bypass: bypass, upstream: "http://localhost:#{bypass.port}", finch_name: Philter.TestFinch}
  end

  describe "GET passthrough" do
    test "forwards GET request and streams response", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/test", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-custom", "value")
        |> Plug.Conn.send_resp(200, "response body")
      end)

      conn =
        conn(:get, "/test")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      assert conn.status == 200
      assert get_resp_header(conn, "x-custom") == ["value"]
      assert conn.resp_body =~ "response body"
    end

    test "forwards query parameters", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/search", fn conn ->
        assert conn.query_string == "q=test&page=1"
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/search?q=test&page=1")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      assert conn.status == 200
    end
  end

  describe "POST with body" do
    test "forwards small request body to sink", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "POST", "/upload", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == "small body"
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:post, "/upload", "small body")
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("content-length", "10")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      assert conn.status == 200
    end

    test "streams large request body", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      body = :crypto.strong_rand_bytes(200_000)
      expected_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      Bypass.expect(bypass, "POST", "/large", fn conn ->
        {:ok, received_body, conn} = Plug.Conn.read_body(conn, length: 500_000)
        received_hash = :crypto.hash(:sha256, received_body) |> Base.encode16(case: :lower)
        assert received_hash == expected_hash
        Plug.Conn.send_resp(conn, 200, "received")
      end)

      conn =
        conn(:post, "/large", body)
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-length", "#{byte_size(body)}")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      assert conn.status == 200
    end
  end

  describe "response streaming" do
    test "streams chunked response from sink", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/stream", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "chunk1")
        {:ok, conn} = Plug.Conn.chunk(conn, "chunk2")
        {:ok, conn} = Plug.Conn.chunk(conn, "chunk3")
        conn
      end)

      conn =
        conn(:get, "/stream")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      assert conn.status == 200
      assert conn.resp_body =~ "chunk1"
      assert conn.resp_body =~ "chunk2"
      assert conn.resp_body =~ "chunk3"
    end
  end

  describe "request observation" do
    test "captures hash and preview of request body", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      body = "observable request body"

      Bypass.expect(bypass, "POST", "/observe", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:post, "/observe", body)
        |> put_req_header("content-length", "#{byte_size(body)}")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      obs = conn.private[:philter_request_observation]
      expected_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      assert obs.hash == expected_hash
      assert obs.preview == body
      assert obs.size == byte_size(body)
    end
  end

  describe "response observation" do
    test "captures hash and preview of response body", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      response_body = "observable response body"

      Bypass.expect(bypass, "GET", "/observe", fn conn ->
        Plug.Conn.send_resp(conn, 200, response_body)
      end)

      conn =
        conn(:get, "/observe")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      obs = conn.private[:philter_response_observation]
      expected_hash = :crypto.hash(:sha256, response_body) |> Base.encode16(case: :lower)

      assert obs.hash == expected_hash
      assert obs.preview == response_body
      assert obs.size == byte_size(response_body)
    end
  end

  describe "path override" do
    test "uses string path override", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/api/v2", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/channels/some-id/api/v2")
        |> ProxyPlug.call(
          ProxyPlug.init(upstream: upstream, finch_name: finch_name, path: "/api/v2")
        )

      assert conn.status == 200
    end

    test "uses function path override", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/prefix/original", fn conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/original")
        |> ProxyPlug.call(
          ProxyPlug.init(
            upstream: upstream,
            finch_name: finch_name,
            path: fn conn -> "/prefix" <> conn.request_path end
          )
        )

      assert conn.status == 200
    end

    test "preserves query string with path override", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/override", fn conn ->
        assert conn.query_string == "foo=bar"
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/original?foo=bar")
        |> ProxyPlug.call(
          ProxyPlug.init(upstream: upstream, finch_name: finch_name, path: "/override")
        )

      assert conn.status == 200
    end
  end

  describe "error handling" do
    test "returns 502 on sink connection refused", %{finch_name: finch_name} do
      conn =
        conn(:get, "/test")
        |> ProxyPlug.call(
          ProxyPlug.init(upstream: "http://localhost:59999", finch_name: finch_name)
        )

      assert conn.status == 502
      assert conn.halted
    end

    test "returns 504 on sink timeout", %{finch_name: finch_name} do
      # Start a TCP server that accepts connections but never responds
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen_socket)

      # Spawn a process to accept the connection but do nothing
      spawn(fn ->
        {:ok, _client_socket} = :gen_tcp.accept(listen_socket)
        # Hold the connection open but never respond
        Process.sleep(10_000)
      end)

      conn =
        conn(:get, "/test")
        |> ProxyPlug.call(
          ProxyPlug.init(
            upstream: "http://localhost:#{port}",
            finch_name: finch_name,
            receive_timeout: 100
          )
        )

      :gen_tcp.close(listen_socket)

      assert conn.status == 504
      assert conn.halted
    end

    test "forwards error status codes from sink", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/error", fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Error")
      end)

      conn =
        conn(:get, "/error")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      assert conn.status == 500
    end
  end

  describe "header forwarding" do
    test "forwards non-hop-by-hop request headers", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/headers", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-custom-header") == ["custom-value"]
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/headers")
        |> put_req_header("x-custom-header", "custom-value")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      assert conn.status == 200
    end

    test "strips hop-by-hop headers from request", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/headers", fn conn ->
        assert Plug.Conn.get_req_header(conn, "connection") == []
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/headers")
        |> put_req_header("connection", "keep-alive")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      assert conn.status == 200
    end

    test "forwards response headers", %{
      bypass: bypass,
      upstream: upstream,
      finch_name: finch_name
    } do
      Bypass.expect(bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-response-header", "response-value")
        |> Plug.Conn.send_resp(200, "ok")
      end)

      conn =
        conn(:get, "/")
        |> ProxyPlug.call(ProxyPlug.init(upstream: upstream, finch_name: finch_name))

      assert get_resp_header(conn, "x-response-header") == ["response-value"]
    end
  end
end

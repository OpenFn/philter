defmodule Philter.EgressIntegrationTest do
  @moduledoc """
  End-to-end tests for the SSRF egress gate wired into `Philter.proxy/2`.

  These exercise the whole path: config resolution, the handler seam, the
  `Philter.Egress` gate, and (on the allowed paths) the Mint resolve-and-pin
  transport against a real Bypass upstream.

  The suite-wide app-env allowlist is `["127.0.0.1", "localhost"]` (see
  `test/test_helper.exs`). To prove that an internal address is BLOCKED we must
  therefore use a host that is NOT on that allowlist and feed the gate synthetic
  addresses through the injected `:resolver` seam, so no real DNS or live
  internal host is needed.
  """
  # async: false — these tests deliberately exercise error paths (egress blocks,
  # transport failures) that emit :error-level logs. ExUnit's capture_log is
  # effectively global, so running concurrently would leak those logs into other
  # modules' log-capture assertions. Running in isolation prevents that bleed.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test
  import Plug.Conn

  @blocked_body "Request blocked by egress policy"

  # A resolver matching `:inet.getaddrs/2`: returns the addresses mapped for the
  # queried family, or nxdomain for any family with no entry.
  defp static_resolver(addresses_by_family) do
    fn _host, family -> Map.get(addresses_by_family, family, {:error, :nxdomain}) end
  end

  # A dead-end upstream port: a socket that listens but never accepts, so a
  # connection completes the TCP handshake but no HTTP response ever comes and
  # the request fails with a receive timeout. Used to prove the gate let a
  # request THROUGH to the transport (a transport failure, not a 403 block).
  # Holding the socket open makes the port ours for the whole test — no race
  # with another async test grabbing a freed ephemeral port.
  defp dead_end_port do
    {:ok, socket} = :gen_tcp.listen(0, mode: :binary, active: false, backlog: 1)
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    port
  end

  # Shared invariant for every blocked request: 403, the fixed body, halted, and
  # crucially NO digits in the body (the resolved IP must never leak to clients).
  defp assert_egress_blocked(conn) do
    assert conn.status == 403
    assert conn.resp_body == @blocked_body
    assert conn.halted
    refute conn.resp_body =~ ~r/\d/
  end

  describe "blocked internal ranges are rejected end-to-end with 403" do
    test "loopback 127.0.0.1" do
      resolver = static_resolver(%{inet: {:ok, [{127, 0, 0, 1}]}})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://attacker.test",
          block_private_networks: true,
          resolver: resolver
        )

      assert_egress_blocked(conn)
      refute conn.resp_body =~ "127"
    end

    test "RFC1918 10.0.0.1" do
      resolver = static_resolver(%{inet: {:ok, [{10, 0, 0, 1}]}})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://attacker.test",
          block_private_networks: true,
          resolver: resolver
        )

      assert_egress_blocked(conn)
    end

    test "CGNAT 100.64.0.1" do
      resolver = static_resolver(%{inet: {:ok, [{100, 64, 0, 1}]}})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://attacker.test",
          block_private_networks: true,
          resolver: resolver
        )

      assert_egress_blocked(conn)
    end

    test "link-local / cloud metadata 169.254.169.254" do
      resolver = static_resolver(%{inet: {:ok, [{169, 254, 169, 254}]}})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://attacker.test",
          block_private_networks: true,
          resolver: resolver
        )

      assert_egress_blocked(conn)
    end

    test "IPv6 loopback ::1" do
      resolver = static_resolver(%{inet6: {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://attacker.test",
          block_private_networks: true,
          resolver: resolver
        )

      assert_egress_blocked(conn)
    end

    test "IPv6 unique-local fc00::1" do
      resolver = static_resolver(%{inet6: {:ok, [{0xFC00, 0, 0, 0, 0, 0, 0, 1}]}})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://attacker.test",
          block_private_networks: true,
          resolver: resolver
        )

      assert_egress_blocked(conn)
    end
  end

  describe "the resolved IP never leaks to the client" do
    test "an IMDS block logs the IP server-side but returns none of its digits" do
      resolver = static_resolver(%{inet: {:ok, [{169, 254, 169, 254}]}})

      {conn, log} =
        with_log(fn ->
          conn(:get, "/")
          |> Philter.proxy(
            upstream: "http://attacker.test",
            block_private_networks: true,
            resolver: resolver
          )
        end)

      assert conn.status == 403
      # The body carries no part of the address (no digits at all).
      refute conn.resp_body =~ "169"
      refute conn.resp_body =~ "254"
      refute conn.resp_body =~ ~r/\d/
      # ...but the full IP IS present in the server-side log for operators.
      assert log =~ "169.254.169.254"
    end
  end

  describe "no observer is started and no finished-callback fires on a block" do
    test "handle_response_finished is not called and no observation is stored" do
      {handler, get_events} = Philter.TestHelpers.test_handler()
      resolver = static_resolver(%{inet: {:ok, [{169, 254, 169, 254}]}})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://attacker.test",
          block_private_networks: true,
          resolver: resolver,
          handler: {handler, %{}}
        )

      assert conn.status == 403

      events = get_events.()
      # The request-started seam runs before the gate, so it fires...
      assert Enum.any?(events, &match?({:request_started, _}, &1))
      # ...but the block is reject-style: no response_finished, no observations.
      refute Enum.any?(events, &match?({:response_finished, _}, &1))
      assert conn.private[:philter_response_observation] == nil
      assert conn.private[:philter_request_observation] == nil
    end
  end

  describe "any internal answer in a multi-answer set rejects the whole set" do
    test "one public + one metadata address is blocked" do
      resolver =
        static_resolver(%{inet: {:ok, [{93, 184, 216, 34}, {169, 254, 169, 254}]}})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://attacker.test",
          block_private_networks: true,
          resolver: resolver
        )

      assert_egress_blocked(conn)
    end
  end

  describe "block_private_networks: false disables the gate" do
    test "a private address is NOT egress-blocked; it proceeds and fails to connect" do
      # Resolve to loopback with a dead-end port. With the gate off the request
      # reaches the transport, which then fails (no response). The point: the
      # outcome is a transport failure (502/504), NOT a 403 block.
      resolver = static_resolver(%{inet: {:ok, [{127, 0, 0, 1}]}})
      port = dead_end_port()

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://internal.test:#{port}",
          block_private_networks: false,
          resolver: resolver,
          receive_timeout: 400
        )

      refute conn.status == 403
      assert conn.status in [502, 504]
      assert conn.halted
    end
  end

  describe "allowed_hosts escape hatch bypasses the gate" do
    test "an allow-listed host resolving to a private IP is not blocked" do
      resolver = static_resolver(%{inet: {:ok, [{127, 0, 0, 1}]}})
      port = dead_end_port()

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://internal.svc:#{port}",
          block_private_networks: true,
          allowed_hosts: ["internal.svc"],
          resolver: resolver,
          receive_timeout: 400
        )

      refute conn.status == 403
      assert conn.status in [502, 504]
    end

    test "allowlist match ignores a trailing dot on the host" do
      resolver = static_resolver(%{inet: {:ok, [{127, 0, 0, 1}]}})
      port = dead_end_port()

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://internal.svc.:#{port}",
          block_private_networks: true,
          allowed_hosts: ["internal.svc"],
          resolver: resolver,
          receive_timeout: 400
        )

      refute conn.status == 403
      assert conn.status in [502, 504]
    end

    test "allowlist match is case-insensitive" do
      resolver = static_resolver(%{inet: {:ok, [{127, 0, 0, 1}]}})
      port = dead_end_port()

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://INTERNAL.SVC:#{port}",
          block_private_networks: true,
          allowed_hosts: ["internal.svc"],
          resolver: resolver,
          receive_timeout: 400
        )

      refute conn.status == 403
      assert conn.status in [502, 504]
    end
  end

  describe "DNS resolution failures map to gateway errors" do
    test "a resolver slower than dns_timeout returns 504 promptly" do
      slow_resolver = fn _host, _family ->
        Process.sleep(5_000)
        {:ok, [{1, 1, 1, 1}]}
      end

      {elapsed_us, conn} =
        :timer.tc(fn ->
          conn(:get, "/")
          |> Philter.proxy(
            upstream: "http://slow.test",
            resolver: slow_resolver,
            dns_timeout: 50
          )
        end)

      assert conn.status == 504
      assert conn.halted
      # Returns well before the resolver's 5s sleep would elapse.
      assert elapsed_us < 2_000_000
    end

    test "a resolver returning nxdomain for both families returns 502" do
      resolver = static_resolver(%{})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "http://void.test",
          resolver: resolver
        )

      assert conn.status == 502
      assert conn.halted
    end
  end

  describe "happy path through the Mint transport against Bypass" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, upstream: "http://localhost:#{bypass.port}"}
    end

    test "GET is proxied and observations are captured", %{bypass: bypass, upstream: upstream} do
      Bypass.expect(bypass, "GET", "/ok", fn conn ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, ~s({"ok": true}))
      end)

      conn =
        conn(:get, "/ok")
        |> Philter.proxy(upstream: upstream)

      assert conn.status == 200
      assert conn.resp_body =~ "ok"

      resp_obs = conn.private[:philter_response_observation]
      assert conn.private[:philter_request_observation].size == 0
      assert resp_obs.size == byte_size(~s({"ok": true}))
      assert resp_obs.hash == Base.encode16(:crypto.hash(:sha256, ~s({"ok": true})), case: :lower)
    end

    test "POST body is streamed and hashed correctly", %{bypass: bypass, upstream: upstream} do
      request_body = ~s({"name": "test"})

      Bypass.expect(bypass, "POST", "/api", fn conn ->
        {:ok, body, conn} = read_body(conn)
        assert body == request_body
        send_resp(conn, 201, "created")
      end)

      conn =
        conn(:post, "/api", request_body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-length", "#{byte_size(request_body)}")
        |> Philter.proxy(upstream: upstream, persistable_content_types: ["application/json"])

      assert conn.status == 201

      req_obs = conn.private[:philter_request_observation]
      assert req_obs.size == byte_size(request_body)
      assert req_obs.body == request_body
      assert req_obs.hash == Base.encode16(:crypto.hash(:sha256, request_body), case: :lower)
    end

    test "exactly one Host header reaches upstream, carrying the hostname not the IP",
         %{bypass: bypass, upstream: upstream} do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/host-check", fn conn ->
        send(test_pid, {:upstream_hosts, Plug.Conn.get_req_header(conn, "host")})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/host-check")
        |> Philter.proxy(upstream: upstream)

      assert conn.status == 200

      assert_receive {:upstream_hosts, hosts}, 2_000
      # Exactly one Host header, and it is the original hostname (with port), not
      # the pinned IP the transport actually dialed.
      assert hosts == ["localhost:#{bypass.port}"]
      refute Enum.any?(hosts, &(&1 =~ "127.0.0.1"))
    end

    test "phase timing has nil queue/idle and reused? false", %{
      bypass: bypass,
      upstream: upstream
    } do
      {handler, get_events} = Philter.TestHelpers.test_handler()

      Bypass.expect(bypass, "GET", "/timing", fn conn ->
        send_resp(conn, 200, "hi")
      end)

      conn =
        conn(:get, "/timing")
        |> Philter.proxy(upstream: upstream, handler: {handler, %{}}, collect_timing: true)

      assert conn.status == 200

      {:response_finished, result} =
        Enum.find(get_events.(), &match?({:response_finished, _}, &1))

      timing = result.timing
      assert is_integer(timing.connect_us) and timing.connect_us >= 0
      assert is_integer(timing.send_us) and timing.send_us >= 0
      assert is_integer(timing.recv_us) and timing.recv_us >= 0
      assert timing.queue_us == nil
      assert timing.idle_time_us == nil
      assert timing.reused_connection? == false
    end
  end

  describe "connect/SNI host cannot diverge from the validated host" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, upstream: "http://localhost:#{bypass.port}"}
    end

    test "a malformed :path cannot redirect the connection to an attacker host", %{
      bypass: bypass,
      upstream: upstream
    } do
      # Guards validated-host vs connect-host divergence: the connection identity
      # (scheme/host/port/SNI) must come from the validated BASE upstream, never
      # from the path-appended URL. A leading-"@" path turns the naive combined
      # URL ("http://localhost:PORT@evil.com") into one whose parsed host is
      # "evil.com". If that combined parse drove the connection, the request would
      # leave for evil.com:80. It must instead still hit the base Bypass upstream.
      test_pid = self()

      Bypass.expect(bypass, fn conn ->
        send(test_pid, {:upstream_hosts, Plug.Conn.get_req_header(conn, "host")})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      conn =
        conn(:get, "/")
        |> Philter.proxy(upstream: upstream, path: "@evil.com")

      # Reached the real base upstream (would be impossible if it dialed evil.com:80).
      assert conn.status == 200

      assert_receive {:upstream_hosts, hosts}, 2_000
      assert hosts == ["localhost:#{bypass.port}"]
      refute Enum.any?(hosts, &(&1 =~ "evil.com"))
    end
  end

  describe "large-body upload does not deadlock" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass, upstream: "http://localhost:#{bypass.port}"}
    end

    test "a multi-MB upload completes when the server drains the body then responds", %{
      bypass: bypass,
      upstream: upstream
    } do
      # Larger than the socket buffer, so the transport must interleave reads and
      # writes; if it didn't, this would deadlock. The server reads the WHOLE
      # body before replying (the success case), so we assert a clean 200.
      body = :crypto.strong_rand_bytes(3 * 1024 * 1024)

      Bypass.expect(bypass, "POST", "/upload", fn conn ->
        {:ok, drained, conn} = read_full_body(conn, "")
        assert byte_size(drained) == byte_size(body)
        send_resp(conn, 200, "drained")
      end)

      task =
        Task.async(fn ->
          conn(:post, "/upload", body)
          |> put_req_header("content-type", "application/octet-stream")
          |> put_req_header("content-length", "#{byte_size(body)}")
          |> Philter.proxy(upstream: upstream, receive_timeout: 15_000)
        end)

      # Timeout guard: a regression that deadlocks fails fast instead of hanging
      # the whole suite.
      result = Task.yield(task, 20_000) || Task.shutdown(task, :brutal_kill)
      assert {:ok, conn} = result, "large-body upload hung (no result within 20s)"

      assert conn.status == 200
      assert conn.private[:philter_request_observation].size == byte_size(body)
    end
  end

  describe "TLS certificate verification is enforced" do
    test "a self-signed upstream certificate is rejected (502, never 200)" do
      # A real HTTPS listener on 127.0.0.1 presenting a self-signed cert for
      # CN=localhost. "localhost" is on the app-env allowlist, so the egress gate
      # passes and resolve-and-pin connects to 127.0.0.1 with SNI=localhost and
      # certificate verification ON. A self-signed cert is not in any trust
      # store, so the TLS handshake MUST fail -> 502. If verification were
      # disabled (verify_none), this cert would be accepted and we'd see 200.
      {port, listen_socket} = start_self_signed_https()
      on_exit(fn -> :ssl.close(listen_socket) end)

      # Pin resolution to the IPv4 listener only (localhost also resolves to ::1,
      # where nothing listens) so the 502 is caused by the TLS trust failure
      # itself, not an IPv6 connect-refused fallback. SNI stays "localhost".
      resolver = static_resolver(%{inet: {:ok, [{127, 0, 0, 1}]}})

      conn =
        conn(:get, "/")
        |> Philter.proxy(
          upstream: "https://localhost:#{port}",
          resolver: resolver,
          receive_timeout: 3_000
        )

      assert conn.status == 502
      refute conn.status == 200
    end
  end

  # --- helpers used by the streaming tests ---------------------------------

  defp read_full_body(conn, acc) do
    case Plug.Conn.read_body(conn, length: 1_000_000, read_length: 1_000_000) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
    end
  end

  defp start_self_signed_https do
    key = X509.PrivateKey.new_rsa(2048)
    cert = X509.Certificate.self_signed(key, "/CN=localhost", template: :server)

    {:ok, listen_socket} =
      :ssl.listen(0,
        cert: X509.Certificate.to_der(cert),
        key: {:RSAPrivateKey, X509.PrivateKey.to_der(key)},
        reuseaddr: true,
        active: false
      )

    {:ok, {_addr, port}} = :ssl.sockname(listen_socket)
    spawn(fn -> tls_accept_loop(listen_socket) end)
    {port, listen_socket}
  end

  # Accept connections so the client reaches the TLS handshake. The client
  # rejects our self-signed cert, so the handshake errors here — which is fine,
  # we only need the port to speak TLS. The loop ends when the socket closes.
  defp tls_accept_loop(listen_socket) do
    case :ssl.transport_accept(listen_socket) do
      {:ok, transport} ->
        _ = :ssl.handshake(transport, 2_000)
        tls_accept_loop(listen_socket)

      {:error, _reason} ->
        :ok
    end
  end
end

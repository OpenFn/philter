defmodule Philter.Elixir119RegressionsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias X509.Certificate.Extension

  defmodule FinishedHandler do
    @behaviour Philter.Handler

    @impl true
    def handle_response_finished(info, test_pid) do
      send(test_pid, {:finished, info.error})
      {:ok, test_pid}
    end
  end

  defp proxy(upstream, opts \\ []) do
    test_pid = self()

    resolver = fn host, family ->
      send(test_pid, {:resolved, host})
      if family == :inet, do: {:ok, [{127, 0, 0, 1}]}, else: {:error, :nxdomain}
    end

    conn(:get, "/")
    |> Philter.proxy(
      [
        upstream: upstream,
        allowed_hosts: ["upstream.test", "localhost"],
        resolver: resolver,
        handler: {FinishedHandler, test_pid},
        connect_timeout: 2_000
      ] ++ opts
    )
  end

  # Elixir 1.19.7's URI.parse/1 returns `port: nil` for ports above 65535,
  # which any default-port fallback would turn into a connection to 80/443.
  describe "an upstream port above 65535 is refused before any connection" do
    for scheme <- ["http", "https"], port <- [65_536, 99_999, 100_000] do
      test "#{scheme}://upstream.test:#{port}" do
        conn = proxy("#{unquote(scheme)}://upstream.test:#{unquote(port)}")

        assert conn.status == 502
        assert conn.halted
        assert_received {:finished, error} when error != nil
        refute_received {:resolved, _}
      end
    end

    test "port 65535 is still dialled" do
      conn = proxy("http://upstream.test:65535")

      assert conn.status == 502
      assert_received {:resolved, ~c"upstream.test"}
      assert_received {:finished, %Mint.TransportError{}}
    end
  end

  # OTP 28.5.0.8 (OTP-20130, RFC 9525) no longer falls back to the subject CN
  # when a certificate carries no subjectAltName.
  describe "TLS hostname verification against a CA-signed upstream" do
    setup do
      ca_key = X509.PrivateKey.new_ec(:secp256r1)
      ca = X509.Certificate.self_signed(ca_key, "/CN=Philter Test CA", template: :root_ca)
      %{ca: ca, ca_key: ca_key}
    end

    test "a certificate with a SAN for the host is accepted", ctx do
      port =
        start_https(ctx,
          subject_alt_name: Extension.subject_alt_name(["localhost"])
        )

      conn =
        proxy("https://localhost:#{port}",
          transport_opts: [cacerts: [X509.Certificate.to_der(ctx.ca)]]
        )

      assert conn.status == 200
      assert_received {:finished, nil}
    end

    test "a CN-only certificate is rejected", ctx do
      port = start_https(ctx, subject_alt_name: false)

      conn =
        proxy("https://localhost:#{port}",
          transport_opts: [cacerts: [X509.Certificate.to_der(ctx.ca)]]
        )

      assert conn.status == 502

      assert_received {:finished,
                       %Mint.TransportError{reason: {:tls_alert, {:bad_certificate, message}}}}

      assert to_string(message) =~ "hostname_check_failed"
    end
  end

  defp start_https(%{ca: ca, ca_key: ca_key}, extensions) do
    key = X509.PrivateKey.new_ec(:secp256r1)

    cert =
      key
      |> X509.PublicKey.derive()
      |> X509.Certificate.new("/CN=localhost", ca, ca_key,
        template: :server,
        extensions: extensions
      )

    {:ok, listen_socket} =
      :ssl.listen(0,
        cert: X509.Certificate.to_der(cert),
        key: {:ECPrivateKey, X509.PrivateKey.to_der(key)},
        reuseaddr: true,
        active: false
      )

    on_exit(fn -> :ssl.close(listen_socket) end)
    {:ok, {_addr, port}} = :ssl.sockname(listen_socket)
    spawn(fn -> serve(listen_socket) end)
    port
  end

  defp serve(listen_socket) do
    with {:ok, transport} <- :ssl.transport_accept(listen_socket),
         {:ok, socket} <- :ssl.handshake(transport, 2_000),
         {:ok, _request} <- :ssl.recv(socket, 0, 2_000) do
      :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
      :ssl.close(socket)
    end
  end
end

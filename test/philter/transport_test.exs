defmodule Philter.TransportTest do
  use ExUnit.Case, async: true

  alias Philter.Transport

  @ok_response "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok"

  describe "connect budget" do
    test "returns an error without spending anywhere near a large receive_timeout" do
      port = closed_loopback_port()
      request = request(port: port, addresses: List.duplicate({127, 0, 0, 1}, 4))

      {elapsed_us, {result, _timing}} =
        :timer.tc(fn ->
          Transport.stream_while(request, %{}, collector(),
            receive_timeout: 30_000,
            connect_timeout: 2_000
          )
        end)

      assert {:error, _error, _acc} = result
      # The connect phase is bounded by the connect budget, never the (much
      # larger) receive timeout, and refused addresses fail fast.
      assert elapsed_us < 1_000_000
    end

    test "stops attempting addresses once the connect budget is spent" do
      port = closed_loopback_port()
      request = request(port: port, addresses: List.duplicate({127, 0, 0, 1}, 50))

      {elapsed_us, {result, _timing}} =
        :timer.tc(fn ->
          Transport.stream_while(request, %{}, collector(),
            receive_timeout: 30_000,
            connect_timeout: 0
          )
        end)

      assert {:error, _error, _acc} = result
      # An exhausted budget short-circuits the whole address list rather than
      # attempting each of the 50 entries in turn.
      assert elapsed_us < 200_000
    end
  end

  describe "socket-scoped mailbox" do
    test "leaves an unrelated socket's messages in the caller's mailbox" do
      port = start_tcp_server(@ok_response)
      request = request(port: port)

      # A message tagged for a socket we do not own must survive the request
      # cycle untouched, while none of our own socket's data messages linger.
      send(self(), {:tcp, :foreign_socket, "junk"})

      {result, _timing} =
        Transport.stream_while(request, %{status: nil}, collector(), receive_timeout: 5_000)

      assert {:ok, %{status: 200}} = result

      assert_received {:tcp, :foreign_socket, "junk"}
      refute_received {:tcp, _socket, _data}
    end
  end

  describe "TLS verification" do
    test "a caller cannot disable peer verification with verify: :verify_none" do
      %{server_config: server_config} = self_signed_tls()
      port = start_tls_server(server_config, @ok_response)

      request = request(scheme: :https, port: port)

      {result, _timing} =
        Transport.stream_while(request, %{status: nil}, collector(),
          receive_timeout: 5_000,
          connect_timeout: 5_000,
          transport_opts: [verify: :verify_none]
        )

      # Verification stays enforced against the untrusted self-signed chain, so
      # the connection fails rather than yielding an unverified 200.
      assert {:error, _error, _acc} = result
      refute match?({:ok, %{status: 200}}, result)
    end

    test "a caller-supplied CA verifies a private upstream over the pinned IP" do
      %{server_config: server_config, cacerts: cacerts} = self_signed_tls()
      port = start_tls_server(server_config, @ok_response)

      request = request(scheme: :https, port: port)

      {result, _timing} =
        Transport.stream_while(request, %{status: nil}, collector(),
          receive_timeout: 5_000,
          connect_timeout: 5_000,
          transport_opts: [cacerts: cacerts]
        )

      assert {:ok, %{status: 200}} = result
    end
  end

  defp request(overrides) do
    %{
      scheme: :http,
      host: "localhost",
      addresses: [{127, 0, 0, 1}],
      port: 0,
      method: "GET",
      path: "/",
      headers: [],
      body: {:stream, []}
    }
    |> Map.merge(Map.new(overrides))
  end

  defp collector do
    fn
      {:status, status}, acc -> {:cont, Map.put(acc, :status, status)}
      _message, acc -> {:cont, acc}
    end
  end

  defp closed_loopback_port do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  defp start_tcp_server(response) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)

    spawn(fn ->
      case :gen_tcp.accept(listen, 5_000) do
        {:ok, socket} ->
          read_request(:gen_tcp, socket)
          :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)

        _ ->
          :ok
      end
    end)

    port
  end

  defp start_tls_server(server_config, response) do
    listen_opts = [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]
    {:ok, listen} = :ssl.listen(0, listen_opts ++ server_config)
    {:ok, {_address, port}} = :ssl.sockname(listen)
    on_exit(fn -> :ssl.close(listen) end)

    spawn(fn ->
      with {:ok, transport} <- :ssl.transport_accept(listen, 5_000),
           {:ok, socket} <- :ssl.handshake(transport, 5_000) do
        read_request(:ssl, socket)
        :ssl.send(socket, response)
        :ssl.close(socket)
      end
    end)

    port
  end

  defp read_request(transport, socket, acc \\ "") do
    case transport.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data
        if String.contains?(acc, "\r\n\r\n"), do: :ok, else: read_request(transport, socket, acc)

      _ ->
        :ok
    end
  end

  # A single self-signed chain (root + leaf) with the leaf carrying a `localhost`
  # SAN and the serverAuth extended key usage, so a client can complete a TLS 1.3
  # handshake against a pinned loopback IP while checking the `localhost`
  # hostname. The chain is untrusted by the OS store, so it verifies only when
  # its CA is supplied explicitly.
  defp self_signed_tls do
    subject_alt_name = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}
    ext_key_usage = {:Extension, {2, 5, 29, 37}, false, [{1, 3, 6, 1, 5, 5, 7, 3, 1}]}
    key = {:namedCurve, :secp256r1}

    %{server_config: server_config} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: key, digest: :sha256],
          intermediates: [],
          peer: [key: key, digest: :sha256, extensions: [subject_alt_name, ext_key_usage]]
        },
        client_chain: %{root: [key: key], intermediates: [], peer: [key: key]}
      })

    %{server_config: server_config, cacerts: Keyword.fetch!(server_config, :cacerts)}
  end
end

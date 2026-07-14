defmodule Philter.Transport do
  @moduledoc false
  # Mint-based streaming transport with resolve-and-pin connection.
  #
  # Connects directly to a caller-validated IP tuple (never re-resolving the
  # hostname, which would reopen the DNS-rebinding hole) while driving TLS SNI
  # and certificate hostname verification against the original hostname via the
  # `:hostname` option. Exposes a `stream_while/4` entry point that folds
  # upstream events through the reducer `Philter.proxy/2` supplies.
  #
  # The connection is opened in active mode and driven synchronously in the
  # calling process via a selective `receive` scoped to this connection's
  # socket, so a caller owning other active sockets keeps their messages.
  # During request-body streaming we drain any pending socket messages between
  # chunks (a non-blocking `receive` with a zero timeout) so an upstream that
  # responds early (401/413/redirect)
  # cannot deadlock a large upload: we always read as well as write, and stop
  # sending the moment the response has started. (A zero-timeout `recv/3` in
  # passive mode is unusable here — Mint treats its timeout as a fatal transport
  # error and closes the socket.)
  #
  # Mint 1.8+ types its connection as an open union of opaque HTTP1/HTTP2
  # structs, so Dialyzer reads every hand-off back to Mint's API here as an
  # opaque-term violation and cascades no-return warnings through the module.
  # Those spurious warnings are filtered in .dialyzer_ignore.exs.

  @type request :: %{
          scheme: :http | :https,
          host: String.t(),
          addresses: [:inet.ip_address()],
          port: :inet.port_number(),
          method: String.t(),
          path: String.t(),
          headers: [{String.t(), String.t()}],
          body: {:stream, Enumerable.t()}
        }

  @type result(acc) :: {:ok, acc} | {:error, Exception.t(), acc}

  @doc """
  Streams `request` to upstream, folding upstream events with `fun`.

  `fun` receives `{:status, code}` / `{:headers, headers}` / `{:data, chunk}` /
  `{:trailers, headers}` messages and returns `{:cont, acc}` or `{:halt, acc}`.

  Returns `{result, timing}` where `result` is `{:ok, acc}` or
  `{:error, exception, acc}` and `timing` is `nil` unless `collect_timing: true`
  was passed, in which case it is a `Philter.Timing.t()` with `connect_us`,
  `send_us` and `recv_us` populated.
  """
  @spec stream_while(request(), acc, (term(), acc -> {:cont, acc} | {:halt, acc}), keyword()) ::
          {result(acc), Philter.Timing.t() | nil}
        when acc: term()
  def stream_while(request, acc, fun, opts) do
    receive_timeout = Keyword.fetch!(opts, :receive_timeout)
    connect_timeout = Keyword.get(opts, :connect_timeout, 5000)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    collect_timing? = Keyword.get(opts, :collect_timing, false)

    connect_start = monotonic()

    case checkout(request, connect_timeout, transport_opts) do
      {:ok, conn} ->
        connect_us = monotonic() - connect_start
        run(conn, request, acc, fun, receive_timeout, connect_us, collect_timing?)

      {:error, error} ->
        {{:error, error, acc}, timing(collect_timing?, monotonic() - connect_start, nil, nil)}
    end
  end

  # Connection acquisition lives behind one function so a future Mint pool keyed
  # on {ip, sni, port} can slot in without touching the send/receive machinery.
  # `connect_timeout` is one overall budget shared across every validated
  # address: each attempt gets whatever remains, so N unresponsive addresses
  # cost at most `connect_timeout` in total rather than that per address.
  defp checkout(request, connect_timeout, caller_transport_opts) do
    base_opts = [
      hostname: request.host,
      protocols: [:http1],
      mode: :active
    ]

    deadline = monotonic_ms() + connect_timeout

    connect_in_order(
      request.scheme,
      request.addresses,
      request.port,
      base_opts,
      caller_transport_opts,
      deadline,
      nil
    )
  end

  defp connect_in_order(_scheme, [], _port, _base, _caller_opts, _deadline, last_error) do
    {:error, last_error || %Mint.TransportError{reason: :nxdomain}}
  end

  defp connect_in_order(scheme, [address | rest], port, base, caller_opts, deadline, last_error) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      {:error, last_error || %Mint.TransportError{reason: :timeout}}
    else
      opts = Keyword.put(base, :transport_opts, transport_opts(scheme, caller_opts, remaining))

      case Mint.HTTP.connect(scheme, address, port, opts) do
        {:ok, conn} ->
          {:ok, conn}

        {:error, error} ->
          connect_in_order(scheme, rest, port, base, caller_opts, deadline, error)
      end
    end
  end

  # Merges the caller's extra transport options (private CA, client cert, …)
  # under the remaining connect budget. TLS verification is pinned to
  # `:verify_peer` and the hostname check (driven by the `:hostname` connect
  # option) is left in force; a caller cannot weaken either, so any `:verify`
  # or `:verify_fun` they supply is dropped before the peer check is enforced.
  defp transport_opts(:https, caller_opts, timeout) do
    caller_opts
    |> Keyword.drop([:verify, :verify_fun])
    |> Keyword.put(:timeout, timeout)
    |> Keyword.put(:verify, :verify_peer)
  end

  defp transport_opts(:http, caller_opts, timeout) do
    caller_opts
    |> Keyword.drop([:verify, :verify_fun])
    |> Keyword.put(:timeout, timeout)
  end

  # `conn` in the `after` block is the original binding, but its socket field is
  # constant across request/stream calls, so closing it closes the live socket
  # on every exit path (success, error, halt, crash). The socket is captured up
  # front so the `after` block can flush any of its residual messages from the
  # caller's mailbox once the connection is closed, leaving nothing behind to
  # surface later as a stray `handle_info`.
  defp run(conn, request, acc, fun, receive_timeout, connect_us, collect?) do
    socket = Mint.HTTP.get_socket(conn)

    try do
      exchange(conn, request, acc, fun, receive_timeout, connect_us, collect?)
    after
      Mint.HTTP.close(conn)
      flush_socket(socket)
    end
  end

  defp exchange(conn, request, acc, fun, receive_timeout, connect_us, collect?) do
    body = body_arg(request.body)
    send_start = monotonic()

    case Mint.HTTP.request(conn, request.method, request.path, request.headers, body) do
      {:ok, conn, ref} ->
        state = new_state(acc)

        {conn, state} =
          case body do
            :stream -> send_body(conn, ref, request.body, state, fun)
            nil -> {conn, state}
          end

        send_us = monotonic() - send_start
        {_conn, state} = receive_loop(conn, ref, state, fun, receive_timeout)
        finish(state, connect_us, send_us, collect?)

      {:error, _conn, error} ->
        {{:error, error, acc}, timing(collect?, connect_us, nil, nil)}
    end
  end

  # build_request_body/2 returns {:stream, []} for the no-body cases; passing
  # nil lets Mint send a plain request (identity encoding) rather than defaulting
  # a streamed body with no content-length to chunked transfer-encoding.
  defp body_arg({:stream, []}), do: nil
  defp body_arg({:stream, _}), do: :stream

  defp new_state(acc) do
    %{
      acc: acc,
      phase: :cont,
      headers_seen?: false,
      first_byte: nil,
      last_byte: nil,
      aborted?: false
    }
  end

  # Interleaves reads between body-chunk sends to avoid the early-response
  # deadlock, and stops sending once the response has started or the socket
  # rejects further writes.
  defp send_body(conn, ref, {:stream, enum}, state, fun) do
    {conn, state} = Enum.reduce_while(enum, {conn, state}, &send_chunk(&1, &2, ref, fun))
    finish_send(conn, state, ref)
  end

  defp send_chunk(chunk, {conn, state}, ref, fun) do
    {conn, state, _status} = drain(conn, ref, state, fun, 0)

    if terminal?(state) do
      {:halt, {conn, state}}
    else
      stream_chunk(conn, ref, chunk, state)
    end
  end

  defp stream_chunk(conn, ref, chunk, state) do
    case Mint.HTTP.stream_request_body(conn, ref, chunk) do
      {:ok, conn} -> {:cont, {conn, state}}
      {:error, conn, _reason} -> {:halt, {conn, %{state | aborted?: true}}}
    end
  end

  defp finish_send(conn, state, ref) do
    if terminal?(state) or state.aborted? do
      {conn, state}
    else
      case Mint.HTTP.stream_request_body(conn, ref, :eof) do
        {:ok, conn} -> {conn, state}
        {:error, conn, _reason} -> {conn, %{state | aborted?: true}}
      end
    end
  end

  defp receive_loop(conn, ref, state, fun, receive_timeout) do
    if terminal?(state) do
      {conn, state}
    else
      case drain(conn, ref, state, fun, receive_timeout) do
        {conn, state, :timeout} ->
          {conn, mark_error(state, %Mint.TransportError{reason: :timeout})}

        {conn, state, :ok} ->
          receive_loop(conn, ref, state, fun, receive_timeout)
      end
    end
  end

  # Waits up to `timeout` for one message from OUR socket and feeds it to Mint.
  # The receive is pinned to this connection's socket so a caller that owns
  # other active sockets keeps their messages in its mailbox. A zero timeout
  # makes this a non-blocking drain (used between body chunks); the receive-phase
  # timeout maps to a 504 upstream. Returns `:timeout` when no message arrived,
  # `:ok` otherwise.
  defp drain(conn, ref, state, fun, timeout) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      {tag, ^socket, _data} = message when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
        apply_message(conn, ref, state, fun, message)

      {tag, ^socket} = message when tag in [:tcp_closed, :ssl_closed] ->
        apply_message(conn, ref, state, fun, message)
    after
      timeout -> {conn, state, :timeout}
    end
  end

  # Discards any of our socket's messages still queued after the connection is
  # closed. Pinned to the socket so unrelated messages are untouched.
  defp flush_socket(socket) do
    receive do
      {tag, ^socket, _data} when tag in [:tcp, :ssl, :tcp_error, :ssl_error] ->
        flush_socket(socket)

      {tag, ^socket} when tag in [:tcp_closed, :ssl_closed] ->
        flush_socket(socket)
    after
      0 -> :ok
    end
  end

  defp apply_message(conn, ref, state, fun, message) do
    case Mint.HTTP.stream(conn, message) do
      {:ok, conn, responses} ->
        {conn, apply_responses(responses, ref, state, fun), :ok}

      {:error, conn, error, responses} ->
        {conn, mark_error(apply_responses(responses, ref, state, fun), error), :ok}

      :unknown ->
        {conn, state, :ok}
    end
  end

  defp apply_responses(responses, ref, state, fun) do
    Enum.reduce(responses, state, fn response, state ->
      if terminal?(state), do: state, else: apply_one(response, ref, state, fun)
    end)
  end

  defp apply_one({:status, ref, status}, ref, state, fun) do
    reduce(fun, {:status, status}, mark_byte(state))
  end

  defp apply_one({:headers, ref, headers}, ref, state, fun) do
    state = mark_byte(state)

    if state.headers_seen? do
      reduce(fun, {:trailers, headers}, state)
    else
      reduce(fun, {:headers, headers}, %{state | headers_seen?: true})
    end
  end

  defp apply_one({:data, ref, data}, ref, state, fun) do
    reduce(fun, {:data, data}, mark_byte(state))
  end

  defp apply_one({:done, ref}, ref, state, _fun), do: %{state | phase: :done}
  defp apply_one({:error, ref, reason}, ref, state, _fun), do: %{state | phase: {:error, reason}}
  defp apply_one(_other, _ref, state, _fun), do: state

  defp reduce(fun, message, state) do
    case fun.(message, state.acc) do
      {:cont, acc} -> %{state | acc: acc}
      {:halt, acc} -> %{state | acc: acc, phase: :halt}
    end
  end

  defp mark_byte(state) do
    now = monotonic()
    %{state | first_byte: state.first_byte || now, last_byte: now}
  end

  defp mark_error(state, error) do
    if terminal?(state), do: state, else: %{state | phase: {:error, error}}
  end

  defp terminal?(%{phase: :done}), do: true
  defp terminal?(%{phase: :halt}), do: true
  defp terminal?(%{phase: {:error, _}}), do: true
  defp terminal?(_state), do: false

  defp finish(state, connect_us, send_us, collect?) do
    result =
      case state.phase do
        :done -> {:ok, state.acc}
        :halt -> {:ok, state.acc}
        {:error, error} -> {:error, error, state.acc}
        :cont -> {:error, %Mint.TransportError{reason: :closed}, state.acc}
      end

    {result, timing(collect?, connect_us, send_us, recv_us(state))}
  end

  defp recv_us(%{first_byte: nil}), do: nil
  defp recv_us(%{first_byte: first, last_byte: nil}), do: max(monotonic() - first, 0)
  defp recv_us(%{first_byte: first, last_byte: last}), do: last - first

  defp timing(false, _connect_us, _send_us, _recv_us), do: nil

  defp timing(true, connect_us, send_us, recv_us) do
    Philter.Timing.new(connect_us, send_us, recv_us)
  end

  defp monotonic, do: System.monotonic_time(:microsecond)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end

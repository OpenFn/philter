defmodule Philter.ProxyPlug do
  @moduledoc """
  Plug interface for streaming HTTP proxying. Use this when you want to proxy
  all requests on a route without pre-processing logic.

  For controller-based usage with authentication or custom routing, see `Philter.proxy/2`.

  ## Router Usage

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        forward "/api/v1", Philter.ProxyPlug,
          upstream: "http://api.internal:4000",
          allowed_hosts: ["api.internal"]

        forward "/legacy", Philter.ProxyPlug,
          upstream: "http://legacy.example.com",
          receive_timeout: 30_000
      end

  The `/api/v1` example targets an internal host, so it must be allowlisted via
  `:allowed_hosts` — by default Philter rejects upstreams that resolve to
  private or otherwise internal addresses. See `Philter.proxy/2` and
  `Philter.Egress` for the SSRF egress policy.

  ## Options

  Takes the same options as `Philter.proxy/2`; `:upstream` is required. See
  `Philter.Config` for global defaults and application configuration.

  ## Accessing Observations

  `forward` hands the request to this plug and nothing in the router runs
  afterwards, so read observations from a handler's
  `c:Philter.Handler.handle_response_finished/2` callback, which receives the
  request and response observations, status, error and timing. See
  `Philter.Handler`.

  ## Comparison with Philter.proxy/2

  Use `Philter.ProxyPlug` when:
    * Forwarding entire route prefixes without pre-processing
    * No authentication or authorization is needed before proxying

  Use `Philter.proxy/2` when:
    * You need authentication before proxying
    * You need to dynamically determine the upstream URL
    * You want to inspect or modify the request before forwarding

  Example with `Philter.proxy/2`:

      def proxy(conn, _params) do
        with {:ok, user} <- authenticate(conn),
             {:ok, upstream} <- resolve_upstream(user) do
          Philter.proxy(conn, upstream: upstream)
        end
      end
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    unless Keyword.has_key?(opts, :upstream) do
      raise ArgumentError,
            "Philter.ProxyPlug requires the :upstream option (e.g., upstream: \"http://api.internal:4000\")"
    end

    if Keyword.has_key?(opts, :headers) and
         (Keyword.has_key?(opts, :extra_headers) or Keyword.has_key?(opts, :strip_headers)) do
      raise ArgumentError,
            ":headers cannot be combined with :extra_headers or :strip_headers"
    end

    opts
  end

  @impl true
  def call(conn, opts) do
    Philter.proxy(conn, opts)
  end
end

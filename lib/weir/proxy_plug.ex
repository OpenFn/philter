defmodule Weir.ProxyPlug do
  @moduledoc """
  Plug interface for streaming HTTP proxying. Use this when you want to proxy
  all requests on a route without pre-processing logic.

  For controller-based usage with authentication or custom routing, see `Weir.proxy/2`.

  ## Router Usage

      defmodule MyAppWeb.Router do
        use MyAppWeb, :router

        forward "/api/v1", Weir.ProxyPlug, upstream: "http://api.internal:4000"
        forward "/legacy", Weir.ProxyPlug,
          upstream: "http://legacy.example.com",
          receive_timeout: 30_000
      end

  ## Options

    * `:upstream` - Base URL of upstream server (required)
    * `:handler` - Handler module or `{module, state}` tuple (optional)
    * `:finch_name` - Finch pool name (default: `Weir.Finch`)
    * `:receive_timeout` - Response timeout in ms (default: `15_000`)
    * `:max_payload_size` - Max body size for accumulation (default: `1_048_576`)
    * `:persistable_content_types` - Content types to accumulate (default: JSON, XML, text)

  See `Weir.Config` for global defaults and application configuration.

  ## Accessing Observations

  After proxying, observations are available in `conn.private`:

      plug :fetch_observations

      defp fetch_observations(conn, _opts) do
        req_obs = conn.private[:weir_request_observation]
        resp_obs = conn.private[:weir_response_observation]
        # req_obs and resp_obs contain: hash, size, preview, timing
        conn
      end

  ## Comparison with Weir.proxy/2

  Use `Weir.ProxyPlug` when:
    * Forwarding entire route prefixes without pre-processing
    * No authentication or authorization is needed before proxying

  Use `Weir.proxy/2` when:
    * You need authentication before proxying
    * You need to dynamically determine the upstream URL
    * You want to inspect or modify the request before forwarding

  Example with `Weir.proxy/2`:

      def proxy(conn, _params) do
        with {:ok, user} <- authenticate(conn),
             {:ok, upstream} <- resolve_upstream(user) do
          Weir.proxy(conn, upstream: upstream)
        end
      end
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    unless Keyword.has_key?(opts, :upstream) do
      raise ArgumentError,
            "Weir.ProxyPlug requires the :upstream option (e.g., upstream: \"http://api.internal:4000\")"
    end

    opts
  end

  @impl true
  def call(conn, opts) do
    Weir.proxy(conn, opts)
  end
end

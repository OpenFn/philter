defmodule Weir.Observer do
  @moduledoc """
  Observes proxy request/response lifecycle events for logging, metrics, and persistence.

  Observers receive callbacks at three points during proxying:

  1. **Request started** - Before sending to upstream
  2. **Response started** - First byte received (TTFB)
  3. **Response finished** - Complete with body observations

  ## Example

      defmodule MyApp.ProxyObserver do
        use Weir.Observer
        require Logger

        @impl true
        def handle_request_started(metadata) do
          # metadata = %{
          #   request_id: term(),
          #   upstream_url: "https://api.example.com/users",
          #   method: "POST",
          #   headers: [{"content-type", "application/json"}, ...],
          #   content_type: "application/json",
          #   started_at: 1706745600000000  # System.monotonic_time(:microsecond)
          # }
          Logger.info("Proxying request", request_id: metadata.request_id)
          :ok
        end

        @impl true
        def handle_response_started(metadata) do
          # metadata = %{
          #   request_id: term(),
          #   status: 200,
          #   headers: [{"content-type", "application/json"}, ...],
          #   content_type: "application/json",
          #   time_to_first_byte_us: 45_230
          # }
          Logger.info("TTFB: \#{metadata.time_to_first_byte_us}us")
          :ok
        end

        @impl true
        def handle_response_finished(result) do
          # result = %{
          #   request_id: term(),
          #   upstream_url: "https://api.example.com/users",
          #   method: "POST",
          #   status: 200,
          #   duration_us: 125_400,
          #   error: nil,
          #   request_observation: %{
          #     hash: "a1b2c3...",      # SHA256 hex digest
          #     size: 1024,             # bytes
          #     body: "...",            # full body if accumulated, nil otherwise
          #     preview: "...",         # first 64KB (always present)
          #     duration_us: 500,
          #     time_to_first_byte_us: nil
          #   },
          #   response_observation: %{
          #     hash: "d4e5f6...",
          #     size: 2048,
          #     body: "{\"id\": 123}",
          #     preview: "{\"id\": 123}",
          #     duration_us: 80_000,
          #     time_to_first_byte_us: 45_230
          #   }
          # }
          MyApp.Repo.insert!(%RequestLog{
            request_hash: result.request_observation.hash,
            response_hash: result.response_observation.hash,
            duration_us: result.duration_us
          })
          :ok
        end
      end

  ## Using Weir.Observer

  `use Weir.Observer` provides default no-op implementations for optional callbacks:

      defmodule MyApp.MinimalObserver do
        use Weir.Observer

        # Only handle_response_finished is required
        @impl true
        def handle_response_finished(result) do
          Logger.info("Request complete", status: result.status)
          :ok
        end
      end

  Without `use`, you must implement all callbacks or declare `@behaviour Weir.Observer`
  and implement them manually.

  ## Callback Order

      handle_request_started/1   # Request received, before upstream call
              ↓
      handle_response_started/1  # First byte from upstream (TTFB)
              ↓
      handle_response_finished/1 # Response complete (or error occurred)

  All callbacks are synchronous. Keep them fast to avoid blocking the response stream.
  `handle_response_finished/1` is always called, even on error - check the `:error` field.
  """

  @typedoc """
  Metadata passed to handle_request_started/1.
  """
  @type request_metadata :: %{
          required(:request_id) => term(),
          required(:upstream_url) => String.t(),
          required(:method) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          required(:content_type) => String.t() | nil,
          required(:started_at) => integer()
        }

  @typedoc """
  Metadata passed to handle_response_started/1.
  """
  @type response_metadata :: %{
          required(:request_id) => term(),
          required(:status) => non_neg_integer(),
          required(:headers) => [{String.t(), String.t()}],
          required(:content_type) => String.t() | nil,
          required(:time_to_first_byte_us) => non_neg_integer()
        }

  @typedoc """
  Observation data for a request or response body.

  - `:hash` - SHA256 hex digest of complete body
  - `:size` - Total body size in bytes
  - `:body` - Full body content if accumulated, nil otherwise
  - `:preview` - First 64KB of body (always present)
  - `:duration_us` - Time to fully transfer body in microseconds
  - `:time_to_first_byte_us` - Time to first byte in microseconds
  """
  @type body_observation :: %{
          required(:hash) => String.t(),
          required(:size) => non_neg_integer(),
          required(:body) => binary() | nil,
          required(:preview) => binary(),
          required(:duration_us) => non_neg_integer(),
          required(:time_to_first_byte_us) => non_neg_integer() | nil
        }

  @typedoc """
  Result passed to handle_response_finished/1.

  Contains observations for both request and response bodies, plus any error
  that occurred during proxying.
  """
  @type finished_result :: %{
          required(:request_id) => term(),
          required(:request_observation) => body_observation(),
          required(:response_observation) => body_observation(),
          required(:error) => term() | nil,
          required(:upstream_url) => String.t(),
          required(:method) => String.t(),
          required(:status) => non_neg_integer() | nil,
          required(:duration_us) => non_neg_integer()
        }

  @doc """
  Called before sending the request to upstream.

  Receives request metadata:

      %{
        request_id: term(),
        upstream_url: String.t(),
        method: String.t(),
        headers: [{String.t(), String.t()}],
        content_type: String.t() | nil,
        started_at: integer()  # System.monotonic_time(:microsecond)
      }

  Use for logging, starting traces, or initializing request-specific state.
  """
  @callback handle_request_started(request_metadata()) :: :ok

  @doc """
  Called when the first byte is received from upstream (TTFB).

  Receives response metadata:

      %{
        request_id: term(),
        status: non_neg_integer(),
        headers: [{String.t(), String.t()}],
        content_type: String.t() | nil,
        time_to_first_byte_us: non_neg_integer()
      }

  Use for recording TTFB metrics or updating traces.
  """
  @callback handle_response_started(response_metadata()) :: :ok

  @doc """
  Called when the response is complete (or an error occurred).

  Always called, even on error. Check `:error` field for failures.

  Receives the finished result:

      %{
        request_id: term(),
        upstream_url: String.t(),
        method: String.t(),
        status: non_neg_integer() | nil,
        duration_us: non_neg_integer(),
        error: term() | nil,
        request_observation: %{
          hash: String.t(),            # SHA256 hex digest
          size: non_neg_integer(),     # total bytes
          body: binary() | nil,        # full body if accumulated
          preview: binary(),           # first 64KB (always present)
          duration_us: non_neg_integer(),
          time_to_first_byte_us: non_neg_integer() | nil
        },
        response_observation: %{...}   # same structure as request_observation
      }

  Use for persisting observations, completing traces, or cleanup.
  """
  @callback handle_response_finished(finished_result()) :: :ok

  @doc false
  @optional_callbacks [handle_request_started: 1, handle_response_started: 1]

  defmacro __using__(_opts) do
    quote do
      @behaviour Weir.Observer

      @impl true
      def handle_request_started(_metadata), do: :ok

      @impl true
      def handle_response_started(_metadata), do: :ok

      defoverridable handle_request_started: 1, handle_response_started: 1
    end
  end
end

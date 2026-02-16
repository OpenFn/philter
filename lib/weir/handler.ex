defmodule Weir.Handler do
  @moduledoc """
  Behaviour for handling proxy lifecycle events.

  Handlers receive lifecycle events, carry state between callbacks, and can
  influence the proxy outcome (e.g., rejecting requests before forwarding).

  State flows: initial args → handle_request_started → handle_response_started
  → handle_response_finished.

  ## Usage

      defmodule MyHandler do
        use Weir.Handler

        @impl true
        def handle_request_started(metadata, state) do
          # Can reject: {:reject, 413, "Too Large", state}
          {:ok, state}
        end

        @impl true
        def handle_response_finished(result, state) do
          {:ok, state}
        end
      end

  ## Callback Order

      handle_request_started/2   # Request received, before upstream call
              ↓
      handle_response_started/2  # First byte from upstream (TTFB)
              ↓
      handle_response_finished/2 # Response complete (or error occurred)

  All callbacks are synchronous. Keep them fast to avoid blocking the response stream.
  `handle_response_finished/2` is always called, even on error — check the `:error` field.
  """

  @typedoc """
  Metadata passed to handle_request_started/2.
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
  Metadata passed to handle_response_started/2.
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
  Result passed to handle_response_finished/2.

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

  Return `{:ok, state}` to proceed, or `{:reject, status, body, state}` to
  abort with a handler-controlled response code and body.
  """
  @callback handle_request_started(request_metadata(), state :: term()) ::
              {:ok, term()} | {:reject, status :: non_neg_integer(), body :: binary(), term()}

  @doc """
  Called when the first byte is received from upstream (TTFB).
  """
  @callback handle_response_started(response_metadata(), state :: term()) ::
              {:ok, term()}

  @doc """
  Called when the response is complete (or an error occurred).

  Always called, even on error. Check `:error` field for failures.
  """
  @callback handle_response_finished(finished_result(), state :: term()) ::
              {:ok, term()}

  @doc false
  @optional_callbacks [handle_request_started: 2, handle_response_started: 2]

  defmacro __using__(_opts) do
    quote do
      @behaviour Weir.Handler

      @impl true
      def handle_request_started(_metadata, state), do: {:ok, state}

      @impl true
      def handle_response_started(_metadata, state), do: {:ok, state}

      defoverridable handle_request_started: 2, handle_response_started: 2
    end
  end
end

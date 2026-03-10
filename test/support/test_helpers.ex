defmodule Philter.TestHelpers do
  @moduledoc """
  Test helpers for Philter tests.

  Provides convenience functions for setting up Bypass mocks,
  creating test responses, and other common test operations.
  """

  @doc """
  Creates a Bypass mock and returns both the bypass and upstream URL.

  ## Examples

      test "my test" do
        %{bypass: bypass, upstream: upstream} = Philter.TestHelpers.bypass_upstream()

        Bypass.expect(bypass, fn conn ->
          Plug.Conn.resp(conn, 200, "OK")
        end)

        # Use upstream URL with Philter...
      end
  """
  @spec bypass_upstream() :: %{bypass: Bypass.t(), upstream: String.t()}
  def bypass_upstream do
    bypass = Bypass.open()
    %{bypass: bypass, upstream: "http://localhost:#{bypass.port}"}
  end

  @doc """
  Sends a JSON response on the given connection.

  ## Examples

      Bypass.expect(bypass, fn conn ->
        Philter.TestHelpers.json_response(conn, 200, %{status: "ok"})
      end)
  """
  @spec json_response(Plug.Conn.t(), integer(), term()) :: Plug.Conn.t()
  def json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  @doc """
  Sends a plain text response on the given connection.

  ## Examples

      Bypass.expect(bypass, fn conn ->
        Philter.TestHelpers.text_response(conn, 200, "Hello, World!")
      end)
  """
  @spec text_response(Plug.Conn.t(), integer(), String.t()) :: Plug.Conn.t()
  def text_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.resp(status, body)
  end

  @doc """
  Creates a test handler module that captures callbacks.

  Returns the handler module and a function to get captured events.

  ## Examples

      {handler, get_events} = Philter.TestHelpers.test_handler()

      # Use handler with Philter...

      events = get_events.()
      assert length(events) == 2
  """
  @spec test_handler() :: {module(), (-> list())}
  def test_handler do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    # Generate unique module name
    module_name =
      Module.concat([Philter.TestHandler, "Handler#{System.unique_integer([:positive])}"])

    defmodule_result =
      Module.create(
        module_name,
        quote do
          use Philter.Handler

          @impl true
          def handle_request_started(metadata, state) do
            Agent.update(unquote(agent), fn events ->
              [{:request_started, metadata} | events]
            end)

            {:ok, state}
          end

          @impl true
          def handle_response_started(metadata, state) do
            Agent.update(unquote(agent), fn events ->
              [{:response_started, metadata} | events]
            end)

            {:ok, state}
          end

          @impl true
          def handle_response_finished(result, state) do
            Agent.update(unquote(agent), fn events ->
              [{:response_finished, result} | events]
            end)

            {:ok, state}
          end
        end,
        Macro.Env.location(__ENV__)
      )

    case defmodule_result do
      {:module, module, _, _} ->
        get_events = fn -> Agent.get(agent, & &1) |> Enum.reverse() end
        {module, get_events}
    end
  end
end

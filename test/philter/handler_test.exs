defmodule Philter.HandlerTest do
  use ExUnit.Case, async: true

  describe "behaviour" do
    defmodule TestHandler do
      @behaviour Philter.Handler

      @impl true
      def handle_request_started(metadata, state) do
        send(state[:test_pid], {:request_started, metadata})
        {:ok, state}
      end

      @impl true
      def handle_response_started(metadata, state) do
        send(state[:test_pid], {:response_started, metadata})
        {:ok, state}
      end

      @impl true
      def handle_response_finished(result, state) do
        send(state[:test_pid], {:response_finished, result})
        {:ok, state}
      end
    end

    test "module implementing behaviour exports callbacks" do
      assert function_exported?(TestHandler, :handle_request_started, 2)
      assert function_exported?(TestHandler, :handle_response_started, 2)
      assert function_exported?(TestHandler, :handle_response_finished, 2)
    end
  end

  describe "use Philter.Handler" do
    defmodule DefaultHandler do
      use Philter.Handler

      @impl true
      def handle_response_finished(result, state) do
        send(state[:test_pid], {:response_finished, result})
        {:ok, state}
      end
    end

    test "provides default implementations for optional callbacks" do
      assert DefaultHandler.handle_request_started(%{}, %{}) == {:ok, %{}}
      assert DefaultHandler.handle_response_started(%{}, %{}) == {:ok, %{}}
    end
  end
end

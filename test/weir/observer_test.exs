defmodule Weir.ObserverTest do
  use ExUnit.Case, async: true

  describe "behaviour" do
    defmodule TestObserver do
      @behaviour Weir.Observer

      @impl true
      def handle_request_started(metadata) do
        send(metadata[:test_pid], {:request_started, metadata})
        :ok
      end

      @impl true
      def handle_response_started(metadata) do
        send(metadata[:test_pid], {:response_started, metadata})
        :ok
      end

      @impl true
      def handle_response_finished(result) do
        send(result[:test_pid], {:response_finished, result})
        :ok
      end
    end

    test "module implementing behaviour exports callbacks" do
      assert function_exported?(TestObserver, :handle_request_started, 1)
      assert function_exported?(TestObserver, :handle_response_started, 1)
      assert function_exported?(TestObserver, :handle_response_finished, 1)
    end
  end

  describe "use Weir.Observer" do
    defmodule DefaultObserver do
      use Weir.Observer

      @impl true
      def handle_response_finished(result) do
        send(result[:test_pid], {:response_finished, result})
        :ok
      end
    end

    test "provides default implementations for optional callbacks" do
      assert DefaultObserver.handle_request_started(%{}) == :ok
      assert DefaultObserver.handle_response_started(%{}) == :ok
    end
  end
end

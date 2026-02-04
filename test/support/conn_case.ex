defmodule Weir.ConnCase do
  @moduledoc """
  Test case template for Plug-based testing.

  This module provides helpers for testing Plug-based applications
  without requiring a Phoenix application to be running.

  ## Usage

      defmodule MyTest do
        use Weir.ConnCase

        test "my test" do
          conn = conn(:get, "/path")
          # ...
        end
      end
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      use Plug.Test
      import Weir.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Plug.Test.conn(:get, "/")}
  end
end

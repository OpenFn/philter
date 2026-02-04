defmodule Weir.ConfigTest do
  use ExUnit.Case, async: true

  alias Weir.Config

  describe "defaults" do
    test "finch_name can be configured via application env" do
      # test_helper.exs sets this to Weir.TestFinch
      assert Config.finch_name() == Weir.TestFinch
    end

    test "receive_timeout has default" do
      assert Config.receive_timeout() == 15_000
    end

    test "max_payload_size has default" do
      assert Config.max_payload_size() == 1_048_576
    end

    test "persistable_content_types has defaults" do
      types = Config.persistable_content_types()
      assert "application/json" in types
      assert "text/plain" in types
    end
  end

  describe "per-request overrides" do
    test "finch_name can be overridden" do
      assert Config.finch_name(finch_name: MyApp.Finch) == MyApp.Finch
    end

    test "receive_timeout can be overridden" do
      assert Config.receive_timeout(receive_timeout: 30_000) == 30_000
    end

    test "max_payload_size can be overridden" do
      assert Config.max_payload_size(max_payload_size: 5_000_000) == 5_000_000
    end

    test "persistable_content_types can be overridden" do
      types = Config.persistable_content_types(persistable_content_types: ["text/csv"])
      assert types == ["text/csv"]
    end
  end

  describe "resolve/1" do
    test "returns all config as map" do
      config = Config.resolve()

      assert Map.has_key?(config, :finch_name)
      assert Map.has_key?(config, :receive_timeout)
      assert Map.has_key?(config, :max_payload_size)
      assert Map.has_key?(config, :persistable_content_types)
    end

    test "applies overrides" do
      config = Config.resolve(receive_timeout: 60_000, max_payload_size: 2_000_000)

      assert config.receive_timeout == 60_000
      assert config.max_payload_size == 2_000_000
    end
  end

  describe "content_type_persistable?/2" do
    test "matches exact content types" do
      allowed = ["application/json", "text/plain"]

      assert Config.content_type_persistable?("application/json", allowed)
      assert Config.content_type_persistable?("text/plain", allowed)
      refute Config.content_type_persistable?("image/png", allowed)
    end

    test "handles content-type with parameters" do
      allowed = ["application/json"]

      assert Config.content_type_persistable?("application/json; charset=utf-8", allowed)
      assert Config.content_type_persistable?("application/json;charset=utf-8", allowed)
    end

    test "is case insensitive" do
      allowed = ["application/json"]

      assert Config.content_type_persistable?("Application/JSON", allowed)
      assert Config.content_type_persistable?("APPLICATION/JSON", allowed)
    end

    test "supports wildcard patterns" do
      allowed = ["text/*", "application/json"]

      assert Config.content_type_persistable?("text/plain", allowed)
      assert Config.content_type_persistable?("text/html", allowed)
      assert Config.content_type_persistable?("text/csv", allowed)
      assert Config.content_type_persistable?("application/json", allowed)
      refute Config.content_type_persistable?("application/xml", allowed)
      refute Config.content_type_persistable?("image/png", allowed)
    end

    test "returns false for nil content type" do
      refute Config.content_type_persistable?(nil, ["application/json"])
    end

    test "returns false for empty allowed list" do
      refute Config.content_type_persistable?("application/json", [])
    end
  end
end

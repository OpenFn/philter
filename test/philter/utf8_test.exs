defmodule Philter.UTF8Test do
  use ExUnit.Case, async: true

  alias Philter.UTF8

  describe "truncate/2" do
    test "returns unchanged if under limit" do
      assert UTF8.truncate("hello", 10) == "hello"
    end

    test "truncates ASCII correctly" do
      assert UTF8.truncate("hello world", 5) == "hello"
    end

    test "truncates at byte boundary for ASCII" do
      assert UTF8.truncate("abcdefgh", 4) == "abcd"
    end

    test "handles empty string" do
      assert UTF8.truncate("", 10) == ""
    end

    test "handles zero limit" do
      assert UTF8.truncate("hello", 0) == ""
    end

    test "preserves complete multi-byte characters" do
      # "é" is 2 bytes (C3 A9)
      # "café" = "caf" (3 bytes) + "é" (2 bytes) = 5 bytes
      assert UTF8.truncate("café", 5) == "café"
      assert UTF8.truncate("café", 4) == "caf"
      assert UTF8.truncate("café", 3) == "caf"
    end

    test "handles 3-byte UTF-8 characters" do
      # "EUR" is 3 bytes (E2 82 AC)
      # "100EUR" = "100" (3 bytes) + "EUR" (3 bytes) = 6 bytes
      assert UTF8.truncate("100\u20AC", 6) == "100\u20AC"
      assert UTF8.truncate("100\u20AC", 5) == "100"
      assert UTF8.truncate("100\u20AC", 4) == "100"
    end

    test "handles 4-byte UTF-8 characters (emoji)" do
      # Party popper is 4 bytes (F0 9F 8E 89)
      # "hi + emoji" = "hi" (2 bytes) + emoji (4 bytes) = 6 bytes
      assert UTF8.truncate("hi\u{1F389}", 6) == "hi\u{1F389}"
      assert UTF8.truncate("hi\u{1F389}", 5) == "hi"
      assert UTF8.truncate("hi\u{1F389}", 4) == "hi"
      assert UTF8.truncate("hi\u{1F389}", 3) == "hi"
    end

    test "handles string of only multi-byte characters" do
      # Japanese characters = 3 characters x 3 bytes = 9 bytes
      assert UTF8.truncate("\u65E5\u672C\u8A9E", 9) == "\u65E5\u672C\u8A9E"
      assert UTF8.truncate("\u65E5\u672C\u8A9E", 8) == "\u65E5\u672C"
      assert UTF8.truncate("\u65E5\u672C\u8A9E", 6) == "\u65E5\u672C"
      assert UTF8.truncate("\u65E5\u672C\u8A9E", 5) == "\u65E5"
      assert UTF8.truncate("\u65E5\u672C\u8A9E", 3) == "\u65E5"
      assert UTF8.truncate("\u65E5\u672C\u8A9E", 2) == ""
    end
  end

  describe "valid?/1" do
    test "returns true for valid UTF-8" do
      assert UTF8.valid?("hello")
      assert UTF8.valid?("cafe")
      assert UTF8.valid?("\u65E5\u672C\u8A9E")
      assert UTF8.valid?("\u{1F389}")
      assert UTF8.valid?("")
    end

    test "returns false for invalid UTF-8" do
      refute UTF8.valid?(<<0xFF, 0xFE>>)
      refute UTF8.valid?(<<0x80>>)
      # Incomplete multi-byte sequence
      refute UTF8.valid?(<<0xC3>>)
    end
  end

  describe "ensure_valid/1" do
    test "returns valid UTF-8 unchanged" do
      assert UTF8.ensure_valid("hello") == {:ok, "hello"}
      assert UTF8.ensure_valid("cafe") == {:ok, "cafe"}
    end

    test "trims incomplete trailing sequence" do
      # "hello" followed by incomplete 2-byte sequence start
      assert UTF8.ensure_valid("hello" <> <<0xC3>>) == {:ok, "hello"}
    end

    test "trims incomplete 3-byte sequence" do
      # Incomplete 3-byte sequence (should start with E2 82 AC for EUR)
      assert UTF8.ensure_valid("hi" <> <<0xE2, 0x82>>) == {:ok, "hi"}
    end

    test "trims incomplete 4-byte sequence" do
      # Incomplete emoji sequence
      assert UTF8.ensure_valid("hi" <> <<0xF0, 0x9F, 0x8E>>) == {:ok, "hi"}
    end

    test "handles empty string" do
      assert UTF8.ensure_valid("") == {:ok, ""}
    end
  end
end

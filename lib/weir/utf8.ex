defmodule Weir.UTF8 do
  @moduledoc """
  UTF-8 safe truncation for streaming data.

  When capturing previews of streamed responses, truncation may occur mid-way
  through a multi-byte UTF-8 character (e.g., "cafe" truncated at byte 4 splits
  the "e"). This module ensures truncated output remains valid UTF-8.
  """

  @doc """
  Truncates a binary to at most `max_bytes`, ensuring valid UTF-8.

  If the binary would be truncated in the middle of a multi-byte character,
  the truncation point is moved backwards to the last complete character.

  Returns the truncated binary.

  ## Examples

      iex> Weir.UTF8.truncate("hello", 10)
      "hello"

      iex> Weir.UTF8.truncate("hello", 3)
      "hel"

      # "e" is 2 bytes (C3 A9), truncating at 5 bytes preserves it
      iex> Weir.UTF8.truncate("cafe", 5)
      "cafe"

      # Truncating at 4 bytes would split "e", so we get "caf"
      iex> Weir.UTF8.truncate("cafe", 4)
      "caf"

  """
  @spec truncate(binary(), non_neg_integer()) :: binary()
  def truncate(binary, max_bytes)
      when is_binary(binary) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(binary) <= max_bytes do
      binary
    else
      truncate_to_valid(binary, max_bytes)
    end
  end

  @doc """
  Validates that a binary is valid UTF-8.

  Returns `true` if the binary is valid UTF-8, `false` otherwise.

  ## Examples

      iex> Weir.UTF8.valid?("hello")
      true

      iex> Weir.UTF8.valid?(<<0xFF, 0xFE>>)
      false

  """
  @spec valid?(binary()) :: boolean()
  def valid?(binary) when is_binary(binary) do
    String.valid?(binary)
  end

  @doc """
  Ensures a binary is valid UTF-8, truncating invalid trailing bytes.

  If the binary ends with an incomplete UTF-8 sequence (common when
  truncating streaming data), those bytes are removed.

  Returns `{:ok, valid_binary}` if successful, or `{:error, :invalid_utf8}`
  if the binary contains invalid UTF-8 that isn't just trailing bytes.

  ## Examples

      iex> Weir.UTF8.ensure_valid("hello")
      {:ok, "hello"}

      # Binary ending with incomplete UTF-8 sequence
      iex> Weir.UTF8.ensure_valid("hello" <> <<0xC3>>)
      {:ok, "hello"}

  """
  @spec ensure_valid(binary()) :: {:ok, binary()} | {:error, :invalid_utf8}
  def ensure_valid(binary) when is_binary(binary) do
    if String.valid?(binary) do
      {:ok, binary}
    else
      # Try to fix by removing trailing incomplete sequence
      case trim_incomplete_tail(binary) do
        {:ok, trimmed} -> {:ok, trimmed}
        :error -> {:error, :invalid_utf8}
      end
    end
  end

  # Private functions

  defp truncate_to_valid(binary, max_bytes) do
    # Take max_bytes and then trim any incomplete UTF-8 sequence at the end
    <<truncated::binary-size(max_bytes), _rest::binary>> = binary
    trim_to_valid_utf8(truncated)
  end

  defp trim_to_valid_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      # Remove bytes from the end until we have valid UTF-8
      # In worst case, we might remove up to 3 bytes (max UTF-8 continuation)
      trim_trailing_bytes(binary, min(3, byte_size(binary)))
    end
  end

  defp trim_trailing_bytes(binary, 0) do
    # Give up - take what we have even if invalid
    binary
  end

  defp trim_trailing_bytes(binary, bytes_to_try) do
    size = byte_size(binary) - 1
    <<trimmed::binary-size(size), _::binary>> = binary

    if String.valid?(trimmed) do
      trimmed
    else
      trim_trailing_bytes(trimmed, bytes_to_try - 1)
    end
  end

  defp trim_incomplete_tail(binary) do
    # Try removing 1-3 bytes from the end to get valid UTF-8
    trim_incomplete_tail(binary, min(3, byte_size(binary)))
  end

  defp trim_incomplete_tail(_binary, 0) do
    :error
  end

  defp trim_incomplete_tail(binary, bytes_to_try) do
    size = byte_size(binary) - 1

    if size < 0 do
      :error
    else
      <<trimmed::binary-size(size), _::binary>> = binary

      if String.valid?(trimmed) do
        {:ok, trimmed}
      else
        trim_incomplete_tail(trimmed, bytes_to_try - 1)
      end
    end
  end
end

defmodule Philter.Config do
  @moduledoc """
  Configuration management for Philter proxy library.

  Configuration can be set at the application level and overridden per-request.

  ## Application Configuration

      config :philter,
        finch_name: MyApp.Finch,
        receive_timeout: 15_000,
        max_payload_size: 1_048_576,
        persistable_content_types: ["application/json", "text/xml", "text/*"]

  ## Per-Request Overrides

  Any option can be overridden when calling `Philter.proxy/2`:

      Philter.proxy(conn,
        upstream: "http://api.example.com",
        receive_timeout: 30_000,
        max_payload_size: 5_242_880
      )

  ## Options

  - `:finch_name` - Name of the Finch pool to use (default: `Philter.Finch`)
  - `:receive_timeout` - Timeout in ms for receiving response (default: 15_000)
  - `:max_payload_size` - Max size in bytes for full body accumulation (default: 1_048_576 / 1MB)
  - `:persistable_content_types` - Content types eligible for full body storage (default: see below)

  ## Default Persistable Content Types

  By default, the following content types are eligible for full body accumulation:

  - `application/json`
  - `application/xml`
  - `text/xml`
  - `text/plain`
  - `text/html`

  Wildcards like `text/*` are supported.
  """

  @default_finch_name Philter.Finch
  @default_receive_timeout 15_000
  @default_max_payload_size 1_048_576
  @default_persistable_content_types [
    "application/json",
    "application/xml",
    "text/xml",
    "text/plain",
    "text/html"
  ]

  @type t :: %{
          finch_name: atom(),
          receive_timeout: pos_integer(),
          max_payload_size: pos_integer(),
          persistable_content_types: [String.t()]
        }

  @doc """
  Returns the configured Finch pool name.

  ## Examples

      iex> Philter.Config.finch_name()
      Philter.Finch

      iex> Philter.Config.finch_name(finch_name: MyApp.Finch)
      MyApp.Finch

  """
  @spec finch_name(keyword()) :: atom()
  def finch_name(opts \\ []) do
    Keyword.get_lazy(opts, :finch_name, fn ->
      Application.get_env(:philter, :finch_name, @default_finch_name)
    end)
  end

  @doc """
  Returns the receive timeout in milliseconds.

  ## Examples

      iex> Philter.Config.receive_timeout()
      15_000

      iex> Philter.Config.receive_timeout(receive_timeout: 30_000)
      30_000

  """
  @spec receive_timeout(keyword()) :: pos_integer()
  def receive_timeout(opts \\ []) do
    Keyword.get_lazy(opts, :receive_timeout, fn ->
      Application.get_env(:philter, :receive_timeout, @default_receive_timeout)
    end)
  end

  @doc """
  Returns the maximum payload size for full body accumulation in bytes.

  ## Examples

      iex> Philter.Config.max_payload_size()
      1_048_576

      iex> Philter.Config.max_payload_size(max_payload_size: 5_242_880)
      5_242_880

  """
  @spec max_payload_size(keyword()) :: pos_integer()
  def max_payload_size(opts \\ []) do
    Keyword.get_lazy(opts, :max_payload_size, fn ->
      Application.get_env(:philter, :max_payload_size, @default_max_payload_size)
    end)
  end

  @doc """
  Returns the list of content types eligible for full body accumulation.

  Supports wildcard patterns like `"text/*"`.

  ## Examples

      iex> Philter.Config.persistable_content_types() |> Enum.member?("application/json")
      true

      iex> Philter.Config.persistable_content_types(persistable_content_types: ["application/json"])
      ["application/json"]

  """
  @spec persistable_content_types(keyword()) :: [String.t()]
  def persistable_content_types(opts \\ []) do
    Keyword.get_lazy(opts, :persistable_content_types, fn ->
      Application.get_env(
        :philter,
        :persistable_content_types,
        @default_persistable_content_types
      )
    end)
  end

  @doc """
  Returns all configuration as a map, with per-request overrides applied.

  Useful for getting the full resolved config in one call.

  ## Examples

      iex> config = Philter.Config.resolve(receive_timeout: 30_000)
      iex> config.receive_timeout
      30_000

  """
  @spec resolve(keyword()) :: t()
  def resolve(opts \\ []) do
    %{
      finch_name: finch_name(opts),
      receive_timeout: receive_timeout(opts),
      max_payload_size: max_payload_size(opts),
      persistable_content_types: persistable_content_types(opts)
    }
  end

  @doc """
  Checks if a content type is eligible for body accumulation.

  Supports exact matches and wildcard patterns (e.g., `text/*`).

  ## Examples

      iex> Philter.Config.content_type_persistable?("application/json", ["application/json", "text/*"])
      true

      iex> Philter.Config.content_type_persistable?("text/plain", ["application/json", "text/*"])
      true

      iex> Philter.Config.content_type_persistable?("image/png", ["application/json", "text/*"])
      false

  """
  @spec content_type_persistable?(String.t() | nil, [String.t()]) :: boolean()
  def content_type_persistable?(nil, _allowed), do: false

  def content_type_persistable?(content_type, allowed) when is_binary(content_type) do
    # Parse content type, stripping parameters like charset
    base_type = content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

    Enum.any?(allowed, fn pattern ->
      matches_pattern?(base_type, String.downcase(pattern))
    end)
  end

  defp matches_pattern?(type, pattern) do
    cond do
      # Exact match
      type == pattern ->
        true

      # Wildcard pattern like "text/*"
      String.ends_with?(pattern, "/*") ->
        prefix = String.trim_trailing(pattern, "/*")
        String.starts_with?(type, prefix <> "/")

      true ->
        false
    end
  end
end

defmodule Weir.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/stuartc/weir"

  def project do
    [
      app: :weir,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description: "Streaming HTTP proxy library with O(1) memory body observation",
      package: package(),

      # Docs
      name: "Weir",
      docs: docs(),
      source_url: @source_url,

      # Dialyzer
      dialyzer: dialyzer(),

      # Xref - exclude optional deps
      xref: [exclude: [Phoenix.Controller, Phoenix.ConnTest, Jason]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto]
      # Note: NO mod: key - library doesn't auto-start supervision
    ]
  end

  defp deps do
    [
      # Required - core functionality
      {:finch, "~> 0.18"},
      {:plug, "~> 1.14"},

      # Optional - enhanced features
      {:phoenix, "~> 1.7", optional: true},
      {:jason, "~> 1.0", optional: true},

      # Development only
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # Test only
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp package do
    [
      name: "weir",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "Weir",
      source_url: @source_url,
      source_ref: "v#{@version}",
      formatters: ["html"],
      extras: [
        "README.md",
        "CHANGELOG.md"
      ],
      groups_for_modules: [
        Core: [Weir, Weir.ProxyPlug],
        Configuration: [Weir.Config],
        Observation: [Weir.Observation, Weir.Observer],
        Internal: [Weir.BodyStream, Weir.ResponseStreamer, Weir.UTF8]
      ],
      nest_modules_by_prefix: [Weir]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix],
      plt_core_path: "priv/plts",
      plt_local_path: "priv/plts"
    ]
  end

  defp aliases do
    [
      lint: ["format --check-formatted", "credo --strict", "dialyzer"],
      "lint.fix": ["format"],
      ci: ["deps.get", "compile --warnings-as-errors", "lint", "test"]
    ]
  end
end

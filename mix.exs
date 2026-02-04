defmodule Weir.MixProject do
  use Mix.Project

  def project do
    [
      app: :weir,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
      # Note: NO mod: key - library doesn't auto-start supervision
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Required - core functionality
      {:finch, "~> 0.18"},
      {:plug, "~> 1.14"},

      # Test only
      {:bypass, "~> 2.1", only: :test}
    ]
  end
end

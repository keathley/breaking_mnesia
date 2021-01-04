defmodule BreakMnesia.MixProject do
  use Mix.Project

  def project do
    [
      app: :break_mnesia,
      version: "0.1.0",
      elixir: "~> 1.11-rc",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, mnesia: :optional],
      mod: {BreakMnesia.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:local_cluster, "~> 1.2"},
      {:schism, "~> 1.0"},
    ]
  end

  defp aliases do
    [
      test: "test --no-start",
    ]
  end
end

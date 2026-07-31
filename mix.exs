defmodule Shelly.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/mdon/shelly"

  # So `mix precommit` runs its test step in :test rather than :dev.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :shelly,
      version: @version,
      elixir: "~> 1.15",
      aliases: aliases(),
      # A floor, not a target: below this something shipped untested.
      test_coverage: [summary: [threshold: 90]],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [:error_handling, :extra_return],
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Shelly"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.4 or ~> 0.5"},
      {:websockex, "~> 0.4"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      # Req's optional plug adapter — lets the OAuth tests answer requests
      # in-process instead of reaching Shelly's servers.
      {:plug, "~> 1.16", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # One gate for the tooling pass: formatting, warnings, unused deps,
  # credo and dialyzer. Code review catches design; this catches dead
  # clauses, drifted formatting and stale deps, and the two sets don't
  # overlap much.
  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "compile --force --warnings-as-errors",
        "test --cover",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "Shelly smart-device client for Elixir: cloud APIs (legacy auth-key, v2, " <>
      "OAuth account access), real-time websocket events, and component-aware " <>
      "status parsing across Gen1-Gen4 hardware."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Shelly API docs" => "https://shelly-api-docs.shelly.cloud"
      },
      maintainers: ["Max Don"]
    ]
  end

  defp docs do
    [
      main: "Shelly",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end

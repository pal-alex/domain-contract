defmodule DomainContract.MixProject do
  use Mix.Project

  def project do
    [
      app: :domain_contract,
      version: "1.0.0",
      elixir: "~> 1.15",
      compilers: [:boundary] ++ Mix.compilers(),
      preferred_cli_env: [verify: :test],
      aliases: [verify: ["format --check-formatted", "compile --warnings-as-errors", "test"]],
      deps: [
        {:boundary, "~> 0.11", runtime: false},
        {:spark, "~> 2.7.3"},
        {:jason, "~> 1.4"},
        {:phoenix_live_view, "~> 1.1", optional: true},
        {:lazy_html, ">= 0.1.0", only: :test}
      ]
    ]
  end

  def application, do: [mod: {DomainContract.Application, []}, extra_applications: [:crypto]]
end

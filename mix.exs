defmodule DomainContract.MixProject do
  use Mix.Project

  def project do
    [
      app: :domain_contract,
      version: "0.2.2",
      elixir: "~> 1.15",
      compilers: [:boundary] ++ Mix.compilers(),
      aliases: [verify: ["format --check-formatted", "compile --warnings-as-errors", "test"]],
      deps: [
        {:boundary, "~> 0.11", runtime: false},
        {:spark, "~> 2.7.3"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end

defmodule DomainContract.MixProject do
  use Mix.Project

  def project do
    [
      app: :domain_contract,
      version: "0.1.0",
      elixir: "~> 1.15",
      compilers: [:boundary] ++ Mix.compilers(),
      deps: [
        {:boundary, "~> 0.11", runtime: false},
        {:spark, "~> 2.7.3"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application, do: []
end

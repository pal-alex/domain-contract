defmodule ArchitectureExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :architecture_example,
      version: "0.1.0",
      build_path: "../../../tmp/architecture_build",
      deps_path: "../../../deps",
      lockfile: "../../../mix.lock",
      deps: [{:domain_contract, path: "../../.."}]
    ]
  end
end

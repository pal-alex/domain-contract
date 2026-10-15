defmodule Mix.Tasks.Domain.Vendor do
  @shortdoc "Copies the locked library source into a build-only vendor directory"
  @moduledoc "Run before Docker builds; does not copy credentials or Git metadata."
  use Boundary, classify_to: DomainContract
  use Mix.Task

  @impl true
  def run(args) do
    {options, [], []} = OptionParser.parse(args, strict: [output: :string])
    {:git, _url, revision, _options} = Map.fetch!(Mix.Dep.Lock.read(), :domain_contract)
    source = Map.fetch!(Mix.Project.deps_paths(), :domain_contract)
    destination = Path.expand(options[:output] || "vendor/domain_contract")
    DomainContract.Source.vendor!(source, revision, destination)
    Mix.shell().info("Vendored contract library #{revision}")
  end
end

defmodule Mix.Tasks.Domain.Check do
  @shortdoc "Checks provider and consumer compatibility in exported contract files"
  @moduledoc "Each argument is a canonical JSON contract exported by its owner."
  use Boundary, classify_to: DomainContract
  use Mix.Task

  @impl true
  def run(paths) do
    Mix.Task.run("app.start")
    if paths == [], do: Mix.raise("usage: mix domain.check contract.json [...]")
    contracts = Enum.flat_map(paths, &(File.read!(&1) |> Jason.decode!() |> List.wrap()))

    case DomainContract.Compatibility.check(contracts) do
      :ok ->
        Mix.shell().info("Domain contracts are compatible (#{length(contracts)} declarations)")

      {:error, errors} ->
        Mix.raise("Incompatible domain contracts: #{inspect(errors, pretty: true)}")
    end
  end
end

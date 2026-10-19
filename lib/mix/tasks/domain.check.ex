defmodule Mix.Tasks.Domain.Check do
  @shortdoc "Checks provider and consumer compatibility in exported contract files"
  @moduledoc """
  Checks candidate exports against immutable owner exports.

      mix domain.check --authority public.json candidate.json consumer.json

  Repeat --authority for multiple catalog artifacts. Authorities supply definitions,
  not active providers. Without authorities, only definitions in the candidate can
  resolve references. No application is started.
  """
  use Boundary, classify_to: DomainContract
  use Mix.Task

  @impl true
  def run(args) do
    {options, paths, invalid} = OptionParser.parse(args, strict: [authority: :keep])
    if invalid != [], do: Mix.raise("invalid domain.check options: #{inspect(invalid)}")
    Mix.Task.run("compile", ["--warnings-as-errors"])

    if paths == [],
      do: Mix.raise("usage: mix domain.check [--authority public.json] candidate.json [...]")

    contracts = read(paths)
    authorities = options |> Keyword.get_values(:authority) |> read()

    case DomainContract.Compatibility.check(contracts, authorities) do
      :ok ->
        Mix.shell().info("Domain contracts are compatible (#{length(contracts)} declarations)")

      {:error, errors} ->
        Mix.raise("Incompatible domain contracts: #{inspect(errors, pretty: true)}")
    end
  end

  defp read(paths), do: Enum.flat_map(paths, &(File.read!(&1) |> Jason.decode!() |> List.wrap()))
end

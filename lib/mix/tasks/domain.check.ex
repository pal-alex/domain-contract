defmodule Mix.Tasks.Domain.Check do
  @shortdoc "Checks provider and consumer compatibility in exported contract files"
  @moduledoc """
  Checks candidate exports against immutable owner exports.

      mix domain.check --authority public.json candidate.json consumer.json

  Repeat --authority for multiple catalog artifacts. Authorities supply definitions,
  not active providers. Without authorities, only definitions in the candidate can
  resolve references.

  To validate source-owner bundles containing both definitions and implementation
  declarations, without selecting active providers:

      mix domain.check --declarations priv/domain_contracts.json other-owner.json

  This checks artifact integrity and conflicting definitions, not provider availability
  or authoritative origin. Deployment activation must still check its selected
  candidate separately. --declarations cannot be combined with --authority.
  No application is started in either mode.
  """
  use Boundary, classify_to: DomainContract
  use Mix.Task

  @impl true
  def run(args) do
    {options, paths, invalid} =
      OptionParser.parse(args, strict: [authority: :keep, declarations: :boolean])

    if invalid != [], do: Mix.raise("invalid domain.check options: #{inspect(invalid)}")

    if options[:declarations] && Keyword.has_key?(options, :authority),
      do: Mix.raise("--declarations cannot be combined with --authority")

    Mix.Task.run("compile", ["--warnings-as-errors"])

    if paths == [],
      do:
        Mix.raise(
          "usage: mix domain.check [--declarations | --authority public.json] contracts.json [...]"
        )

    contracts = read(paths)
    authorities = options |> Keyword.get_values(:authority) |> read()

    {result, success} =
      if options[:declarations] do
        {DomainContract.Compatibility.validate(contracts), "Domain declarations are valid"}
      else
        {DomainContract.Compatibility.check(contracts, authorities),
         "Domain contracts are compatible"}
      end

    case result do
      :ok ->
        Mix.shell().info("#{success} (#{length(contracts)} declarations)")

      {:error, errors} ->
        Mix.raise("Incompatible domain contracts: #{inspect(errors, pretty: true)}")
    end
  end

  defp read(paths),
    do:
      Enum.flat_map(
        paths,
        &(File.read!(&1) |> Jason.decode!() |> DomainContract.Schemas.unbundle())
      )
end

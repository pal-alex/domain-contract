defmodule Mix.Tasks.Domain.Inputs do
  @shortdoc "Selects owner exports for an independent consumer build"
  use Boundary, classify_to: DomainContract
  use Mix.Task

  @impl true
  def run(args) do
    {options, paths, invalid} = OptionParser.parse(args, strict: [output: :string, module: :keep])

    if paths == [] or invalid != [] or is_nil(options[:output]),
      do:
        Mix.raise(
          "usage: mix domain.inputs --output priv/domain_inputs.json [--module Elixir.Owner] owner-export.json ..."
        )

    requested = Keyword.get_values(options, :module)
    owners = Enum.flat_map(paths, &(DomainContract.Reference.load(&1) |> List.wrap()))

    owners =
      if requested == [], do: owners, else: Enum.filter(owners, &(&1["module"] in requested))

    owners = owners |> Enum.map(&DomainContract.Schemas.definition/1) |> Enum.uniq()

    if length(Enum.uniq_by(owners, & &1["module"])) != length(owners),
      do: Mix.raise("ambiguous owner revisions in selected inputs")

    missing = requested -- Enum.map(owners, & &1["module"])
    if missing != [], do: Mix.raise("missing selected owners: #{inspect(missing)}")

    if DomainContract.Compatibility.validate(owners) != :ok,
      do: Mix.raise("invalid owner metadata")

    File.write!(
      options[:output],
      owners |> DomainContract.Schemas.bundle() |> DomainContract.Info.encode()
    )
  end
end

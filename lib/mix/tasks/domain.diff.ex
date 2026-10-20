defmodule Mix.Tasks.Domain.Diff do
  @shortdoc "Compares two exported public architectures"
  use Boundary, classify_to: DomainContract
  use Mix.Task

  def run(args) do
    {options, paths, invalid} = OptionParser.parse(args, strict: [json: :string])

    if length(paths) != 2 or invalid != [],
      do: Mix.raise("usage: mix domain.diff before.json after.json [--json report.json]")

    [before, after_state] = Enum.map(paths, &(File.read!(&1) |> Jason.decode!() |> List.wrap()))
    report = DomainContract.Architecture.diff(before, after_state)
    Mix.shell().info(DomainContract.Architecture.render(report))
    if options[:json], do: File.write!(options[:json], DomainContract.Info.encode(report) <> "\n")
    if report.incompatible != [], do: Mix.raise("incompatible public contract changes")
  end
end

defmodule Mix.Tasks.Domain.Diff do
  @shortdoc "Compares two exported public architectures"
  use Boundary, classify_to: DomainContract
  use Mix.Task

  def run(args) do
    {options, paths, invalid} = OptionParser.parse(args, strict: [json: :string, sources: :keep])

    if length(paths) != 2 or invalid != [],
      do:
        Mix.raise(
          "usage: mix domain.diff before.json after.json [--json report.json] [--sources 'lib/**/*.ex']"
        )

    [before, after_state] = Enum.map(paths, &(File.read!(&1) |> Jason.decode!() |> List.wrap()))

    sources =
      options
      |> Keyword.get_values(:sources)
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{&1, File.read!(&1)})

    diagnostics = DomainContract.Architecture.diagnose(sources, after_state)
    report = DomainContract.Architecture.diff(before, after_state, diagnostics)
    Mix.shell().info(DomainContract.Architecture.render(report))
    if options[:json], do: File.write!(options[:json], DomainContract.Info.encode(report) <> "\n")
    if report.incompatible != [], do: Mix.raise("incompatible public contract changes")

    if Enum.any?(diagnostics, &(&1.severity == :error)),
      do: Mix.raise("unauthorized architectural interactions")
  end
end

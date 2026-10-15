defmodule Mix.Tasks.Domain.Contract do
  @shortdoc "Exports a compiled domain contract as canonical JSON"
  @moduledoc "Exports owner declarations; does not prove behavioral guarantees."
  use Boundary, classify_to: DomainContract
  use Mix.Task

  @impl true
  def run(args) do
    {options, positional, invalid} = OptionParser.parse(args, strict: [output: :string])

    if length(positional) != 1 or invalid != [] do
      Mix.raise("usage: mix domain.contract Module [--output file]")
    end

    Mix.Task.run("compile", ["--warnings-as-errors"])
    module = Module.concat([hd(positional)])
    Code.ensure_loaded!(module)
    json = DomainContract.Info.json(module) <> "\n"

    case options[:output] do
      nil -> Mix.shell().info(json)
      file -> File.write!(file, json)
    end
  end
end

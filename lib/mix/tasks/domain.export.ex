defmodule Mix.Tasks.Domain.Export do
  @shortdoc "Exports every domain owned by the current Mix application"
  @moduledoc "Exports declarations without starting the application or its dependencies."
  use Boundary, classify_to: DomainContract
  use Mix.Task

  @impl true
  def run(args) do
    {options, [], []} = OptionParser.parse(args, strict: [output: :string])
    Mix.Task.run("compile", ["--warnings-as-errors"])
    app = Mix.Project.config()[:app]
    Application.load(app)

    contracts =
      app
      |> Application.spec(:modules)
      |> Enum.sort()
      |> Enum.flat_map(fn module ->
        Code.ensure_loaded!(module)

        if function_exported?(module, :spark_dsl_config, 0) and
             Spark.Dsl.Extension.get_entities(module.spark_dsl_config(), [:contract]) != [] do
          [module |> DomainContract.Info.json() |> Jason.decode!()]
        else
          []
        end
      end)

    json = Jason.encode!(contracts, pretty: true) <> "\n"

    case options[:output] do
      nil -> Mix.shell().info(json)
      path -> File.write!(path, json)
    end
  end
end

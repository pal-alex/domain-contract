defmodule Mix.Tasks.Domain.Export do
  @shortdoc "Exports every domain declaration in the current Mix application"
  @moduledoc """
  Exports root declarations without starting the application or its dependencies.

  The source-owner bundle includes authoritative definitions and implementation or
  consumer declarations. It is not a selection of active providers. Validate it with
  `mix domain.check --declarations`; deployment tooling must separately check its
  selected entry-point declarations against independent authoritative artifacts.
  """
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
        case :code.which(module) do
          path when is_list(path) ->
            case DomainContract.Artifact.from_beam(File.read!(path)) do
              {:ok, artifact} -> [artifact]
              {:error, :not_contract} -> []
              error -> Mix.raise("invalid compiled contract: #{inspect({module, error})}")
            end

          _ ->
            []
        end
      end)

    json = DomainContract.Info.encode(contracts) <> "\n"

    case options[:output] do
      nil -> Mix.shell().info(json)
      path -> File.write!(path, json)
    end
  end
end

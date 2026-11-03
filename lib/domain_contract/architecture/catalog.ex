defmodule DomainContract.Architecture.Catalog do
  @moduledoc false
  alias DomainContract.Architecture.Beam

  # Read the selected dependency applications' ownership declarations, never
  # their runtime entry functions. Observed references only discover policies;
  # they do not grant dependencies or exports to the caller.
  def extend(beams, references) do
    targets =
      Enum.flat_map(references, fn {_, refs} ->
        Enum.flat_map(refs, fn
          %{target: {module, _, _}} -> [module]
          %{contract: module} -> [module]
          _ -> []
        end)
      end)

    declared =
      Enum.flat_map(beams, fn {_, beam} ->
        case Keyword.get(beam.attributes, :domain_contract_artifact) do
          [%{"metadata" => metadata, "consumes" => consumes}]
          when is_map(metadata) and is_list(consumes) ->
            uses =
              case metadata["architecture"] do
                %{"uses" => uses} when is_list(uses) -> uses
                _ -> []
              end

            uses ++ for %{"module" => name} <- consumes, do: name

          _ ->
            []
        end
      end)

    headers =
      (targets ++ declared)
      |> Enum.uniq()
      |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
      |> Enum.flat_map(fn target ->
        case Beam.header(target) do
          {:ok, beam} -> [beam]
          :error -> []
        end
      end)

    owners =
      headers
      |> Enum.map(&Path.dirname(&1.path))
      |> Enum.uniq()
      |> Enum.flat_map(&inventory/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(beams, &1))
      |> Enum.flat_map(fn module ->
        case Beam.header(module) do
          {:ok, beam} ->
            if Keyword.has_key?(beam.attributes, :domain_contract_artifact) do
              case Beam.read(module) do
                {:ok, complete} -> [complete]
                _ -> [beam]
              end
            else
              []
            end

          :error ->
            []
        end
      end)

    Map.merge(Map.new(headers ++ owners, &{&1.module, &1}), beams)
  end

  defp inventory(directory) do
    directory
    |> Path.join("*.app")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case :file.consult(String.to_charlist(path)) do
        {:ok, [{:application, _, properties}]} -> Keyword.get(properties, :modules, [])
        _ -> []
      end
    end)
  end
end

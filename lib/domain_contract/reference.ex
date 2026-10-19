defmodule DomainContract.Reference do
  @moduledoc "An exact reference to an authoritative interface, resolved when declarations compile."
  defstruct [
    :name,
    :version,
    :contract,
    :kind,
    :definition,
    optional: false,
    __spark_metadata__: nil
  ]

  alias DomainContract.Info

  @doc "Resolves a module, canonical export, or JSON file into an immutable interface snapshot."
  def resolve(source, name, version, kind \\ nil) do
    matches =
      for contract <- List.wrap(load(source)),
          :ok = DomainContract.Artifact.validate(contract),
          interface <- contract["interfaces"],
          interface["name"] == name and interface["version"] == version and
            (is_nil(kind) or interface["kind"] == to_string(kind)),
          do: {contract, interface}

    case matches do
      [{contract, interface}] ->
        snapshot(interface, contract["entities"], contract["description"])

      [] ->
        raise ArgumentError, "unknown contract #{inspect({kind, name, version})}"

      _ ->
        raise ArgumentError, "ambiguous contract #{inspect({kind, name, version})}"
    end
  end

  def load(source) when is_atom(source) do
    Code.ensure_compiled!(source)
    source |> Info.contract() |> Info.canonical()
  end

  def load(source) when is_map(source), do: Info.canonical(source)

  def load(path) when is_binary(path) do
    path |> File.read!() |> Jason.decode!()
  end

  @doc false
  def snapshot(interface, entities, description \\ nil) do
    roots =
      for operation <- interface["operations"],
          direction <- ["input", "output"],
          name <- root_entities(operation, direction),
          do: name

    selected = reachable(roots, Map.new(entities, &{&1["name"], &1}), MapSet.new())

    definition = %{
      "description" => description,
      "interface" => interface,
      "entities" =>
        entities
        |> Enum.filter(&MapSet.member?(selected, &1["name"]))
        |> Enum.sort_by(& &1["name"])
    }

    Map.put(definition, "digest", digest(definition))
  end

  defp root_entities(operation, direction) do
    case Map.fetch(operation, direction <> "_type") do
      {:ok, type} -> references(type)
      :error -> [operation[direction]]
    end
  end

  @doc "Checks snapshot integrity. The digest identifies the complete interface, including descriptions."
  def valid?(%{"interface" => interface, "entities" => entities, "digest" => digest} = definition)
      when is_map(interface) and is_list(entities) and is_binary(digest) do
    digest == digest(Map.delete(definition, "digest")) and
      definition == snapshot(interface, entities, definition["description"])
  rescue
    _ -> false
  end

  def valid?(_), do: false

  defp digest(definition) do
    :crypto.hash(:sha256, Info.encode(definition)) |> Base.encode16(case: :lower)
  end

  defp reachable([], _, seen), do: seen

  defp reachable([name | rest], definitions, seen) do
    if MapSet.member?(seen, name) do
      reachable(rest, definitions, seen)
    else
      entity = Map.fetch!(definitions, name)
      children = Enum.flat_map(entity["fields"], &references(&1["type"]))
      reachable(children ++ rest, definitions, MapSet.put(seen, name))
    end
  end

  defp references([kind, name]) when kind in ["entity", "open_entity"], do: [name]

  defp references([container, type]) when container in ["list", "dictionary"],
    do: references(type)

  defp references(["variant", choices]),
    do: Enum.flat_map(choices, fn {_, type} -> references(type) end)

  defp references(_), do: []
end

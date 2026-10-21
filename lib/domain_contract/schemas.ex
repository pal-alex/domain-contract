defmodule DomainContract.Schemas do
  @moduledoc "Deduplicated build/admission schemas. References identify content, never confer authority."
  alias DomainContract.Info
  alias DomainContract.Reference

  def definition(owner), do: Map.drop(owner, ~w(consumes subscriptions schemas digest))
  def id(%{"schema" => id}) when is_binary(id), do: id
  def id(owner), do: owner |> definition() |> Reference.digest()

  def reference(owner),
    do: %{"module" => owner["module"], "schema" => id(owner)}

  def with_requirements(owner, references) do
    schemas = Map.new(references, &{&1["schema"], fetch!(&1)}) |> Map.delete(id(owner))

    owner
    |> Map.delete("digest")
    |> Map.put("consumes", references)
    |> Map.put("schemas", schemas)
  end

  def index(owners) do
    Enum.reduce(owners, %{}, fn owner, index ->
      owner = if Map.has_key?(owner, "schema"), do: expand(owner), else: owner

      index
      |> merge(Map.get(owner, "schemas", %{}))
      |> merge(%{id(owner) => definition(owner)})
    end)
  end

  def merge(left, right) do
    Map.merge(left, right, fn id, first, second ->
      if first != second, do: raise(ArgumentError, "conflicting schema #{id}")
      first
    end)
  end

  def fetch!(%{"schema" => id, "module" => module}, source \\ %{}) do
    source =
      if Map.has_key?(source, "module") and Map.has_key?(source, "operations"),
        do: index([source]),
        else: source

    schema =
      case Map.fetch(Map.get(source, "schemas", source), id) do
        {:ok, schema} -> schema
        :error -> DomainContract.SchemaStore.fetch!(id)
      end

    if schema["module"] != module, do: raise(ArgumentError, "schema owner mismatch: #{module}")
    schema
  end

  def bundle(owners) do
    owners = Enum.map(owners, &Info.canonical/1)

    %{
      "format_version" => 8,
      "contracts" =>
        Enum.map(owners, fn owner ->
          owner |> Map.take(~w(module consumes subscriptions)) |> Map.put("schema", id(owner))
        end),
      "schemas" => index(owners)
    }
  end

  def unbundle(%{"format_version" => 8, "contracts" => owners, "schemas" => schemas}) do
    Enum.map(owners, fn owner ->
      wanted = (owner["consumes"] || []) ++ (owner["subscriptions"] || [])
      own_id = owner["schema"]
      required = wanted |> Enum.map(& &1["schema"]) |> Enum.reject(&(&1 == own_id))
      definition = Map.fetch!(schemas, own_id)

      if definition["module"] != owner["module"] or id(definition) != own_id,
        do: raise(ArgumentError, "invalid bundle owner schema")

      definition
      |> Map.merge(Map.take(owner, ~w(consumes subscriptions)))
      |> Map.put("schemas", Map.take(schemas, required))
      |> then(&Map.put(&1, "digest", Reference.digest(&1)))
    end)
  end

  def unbundle(owners) when is_list(owners), do: owners
  def unbundle(%{"format_version" => 8, "module" => _} = owner), do: [owner]

  @doc "Deduplicates all contract metadata in a bootstrap or admission payload."
  def pack(payload) do
    {payload, schemas} = pack_value(payload, %{})
    Map.put(payload, "contract_schemas", schemas)
  end

  def unpack(%{"contract_schemas" => schemas} = payload) do
    if not Enum.all?(schemas, fn {id, schema} ->
         id(schema) == id and DomainContract.Artifact.validate(schema) == :ok
       end),
       do: raise(ArgumentError, "invalid bootstrap schema index")

    payload |> Map.delete("contract_schemas") |> unpack_value(schemas)
  end

  def unpack(payload), do: payload

  defp pack_value(%{"format_version" => 8, "operations" => _, "module" => _} = owner, schemas),
    do:
      {Map.take(owner, ~w(module consumes subscriptions)) |> Map.put("schema", id(owner)),
       merge(schemas, index([owner]))}

  defp pack_value(map, schemas) when is_map(map) do
    Enum.reduce(map, {%{}, schemas}, fn {key, value}, {result, schemas} ->
      {value, schemas} = pack_value(value, schemas)
      {Map.put(result, key, value), schemas}
    end)
  end

  defp pack_value(list, schemas) when is_list(list) do
    Enum.map_reduce(list, schemas, &pack_value/2)
  end

  defp pack_value(value, schemas), do: {value, schemas}

  defp unpack_value(%{"schema" => _, "module" => _} = owner, schemas) do
    [owner] = unbundle(%{"format_version" => 8, "contracts" => [owner], "schemas" => schemas})
    owner
  end

  defp unpack_value(map, schemas) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, unpack_value(value, schemas)} end)

  defp unpack_value(list, schemas) when is_list(list),
    do: Enum.map(list, &unpack_value(&1, schemas))

  defp unpack_value(value, _schemas), do: value

  def expand(%{"schema" => _} = consumer) do
    owner = fetch!(consumer)
    refs = (consumer["consumes"] || []) ++ (consumer["subscriptions"] || [])
    schemas = Map.new(refs, &{&1["schema"], fetch!(&1)}) |> Map.delete(consumer["schema"])

    owner
    |> Map.merge(Map.take(consumer, ~w(consumes subscriptions)))
    |> Map.put("schemas", schemas)
  end

  def operation(schema, name) do
    case Enum.find(schema["operations"], &(&1["name"] == to_string(name))) do
      nil ->
        %{"operations" => [], "entities" => []}

      declaration ->
        roots =
          for key <- ~w(input output),
              do: declaration[key <> "_type"] || ["entity", declaration[key]]

        entities = reachable(schema["entities"], referenced(roots), MapSet.new())

        %{
          "format_version" => 8,
          "module" => schema["module"],
          "operations" => [declaration],
          "entities" => entities
        }
    end
  end

  defp reachable(entities, names, seen) do
    wanted = MapSet.difference(names, seen)
    selected = Enum.filter(entities, &MapSet.member?(wanted, &1["name"]))

    if selected == [],
      do: [],
      else: selected ++ reachable(entities, referenced(selected), MapSet.union(seen, wanted))
  end

  defp referenced([kind, name]) when kind in ~w(entity open_entity), do: MapSet.new([name])
  defp referenced(map) when is_map(map), do: map |> Map.values() |> referenced()

  defp referenced(list) when is_list(list),
    do: Enum.reduce(list, MapSet.new(), &MapSet.union(referenced(&1), &2))

  defp referenced(_), do: MapSet.new()

  @doc "Drops documentation only in the execution projection; exports keep the full public contract."
  def runtime(owner) do
    owner
    |> Map.drop(~w(description responsibility digest))
    |> Map.update!("entities", fn entities ->
      Enum.map(entities, fn entity ->
        entity
        |> Map.delete("description")
        |> Map.update!("fields", &Enum.map(&1, fn field -> Map.delete(field, "description") end))
      end)
    end)
    |> then(fn schema ->
      Enum.reduce(~w(operations commands notifications props slots), schema, fn key, result ->
        Map.update!(result, key, &Enum.map(&1, fn item -> Map.delete(item, "description") end))
      end)
    end)
  end
end

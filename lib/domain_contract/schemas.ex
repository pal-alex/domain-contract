defmodule DomainContract.Schemas do
  @moduledoc "Deduplicated build/admission schemas. References identify content, never confer authority."
  alias DomainContract.Info
  alias DomainContract.Reference

  @envelope ~w(metadata responsibility description consumes subscriptions)

  def definition(owner), do: owner |> Map.drop(@envelope ++ ~w(schemas digest)) |> runtime()

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
      "format_version" => 9,
      "contracts" => Enum.map(owners, &descriptor/1),
      "schemas" => index(owners)
    }
  end

  def unbundle(%{"format_version" => 9, "contracts" => owners, "schemas" => schemas}) do
    Enum.map(owners, fn owner ->
      wanted = (owner["consumes"] || []) ++ (owner["subscriptions"] || [])
      own_id = owner["schema"]
      required = wanted |> Enum.map(& &1["schema"]) |> Enum.reject(&(&1 == own_id))
      definition = Map.fetch!(schemas, own_id)

      if definition["module"] != owner["module"] or id(definition) != own_id,
        do: raise(ArgumentError, "invalid bundle owner schema")

      definition
      |> restore_documentation(owner)
      |> Map.merge(Map.take(owner, @envelope))
      |> Map.put("schemas", Map.take(schemas, required))
      |> then(&Map.put(&1, "digest", Reference.digest(&1)))
    end)
  end

  def unbundle(owners) when is_list(owners), do: owners
  def unbundle(%{"format_version" => 9, "module" => _} = owner), do: [owner]

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

  @doc "Restores a payload held by a trusted preparation or current installation, without revalidating its immutable index."
  def unpack_prepared(%{"contract_schemas" => schemas} = payload),
    do: payload |> Map.delete("contract_schemas") |> restore_value(schemas)

  def unpack_prepared(payload), do: payload

  defp pack_value(%{"format_version" => 9, "operations" => _, "module" => _} = owner, schemas),
    do: {descriptor(owner), merge(schemas, index([owner]))}

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
    [owner] = unbundle(%{"format_version" => 9, "contracts" => [owner], "schemas" => schemas})
    owner
  end

  defp unpack_value(map, schemas) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, unpack_value(value, schemas)} end)

  defp unpack_value(list, schemas) when is_list(list),
    do: Enum.map(list, &unpack_value(&1, schemas))

  defp unpack_value(value, _schemas), do: value

  defp restore_value(%{"schema" => own_id, "module" => module} = owner, schemas) do
    definition = Map.fetch!(schemas, own_id)
    if definition["module"] != module, do: raise(ArgumentError, "prepared schema owner mismatch")
    refs = (owner["consumes"] || []) ++ (owner["subscriptions"] || [])
    required = refs |> Enum.map(& &1["schema"]) |> Enum.reject(&(&1 == own_id))

    definition
    |> restore_documentation(owner)
    |> Map.merge(Map.take(owner, @envelope ++ ["digest"]))
    |> Map.put("schemas", Map.take(schemas, required))
  end

  defp restore_value(map, schemas) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, restore_value(value, schemas)} end)

  defp restore_value(list, schemas) when is_list(list),
    do: Enum.map(list, &restore_value(&1, schemas))

  defp restore_value(value, _schemas), do: value

  defp descriptor(owner) do
    documentation =
      Map.new(~w(entities operations commands notifications props slots), fn key ->
        {key, documentation(Map.get(owner, key, []))}
      end)

    owner
    |> Map.take(@envelope ++ ~w(module digest))
    |> Map.put("schema", id(owner))
    |> Map.put("documentation", documentation)
  end

  defp documentation(items) do
    Map.new(items, fn item ->
      docs = Map.take(item, ["description"])

      docs =
        if item["fields"], do: Map.put(docs, "fields", documentation(item["fields"])), else: docs

      {item["name"], docs}
    end)
  end

  defp restore_documentation(schema, owner) do
    Enum.reduce(Map.get(owner, "documentation", %{}), schema, fn {key, docs}, result ->
      if key not in ~w(entities operations commands notifications props slots),
        do: raise(ArgumentError, "invalid documentation surface")

      Map.update!(result, key, &documented(&1, docs))
    end)
  end

  defp documented(items, docs) do
    Enum.map(items, fn item ->
      metadata = Map.get(docs, item["name"], %{})
      item = Map.merge(item, Map.take(metadata, ["description"]))

      if item["fields"],
        do: Map.update!(item, "fields", &documented(&1, Map.get(metadata, "fields", %{}))),
        else: item
    end)
  end

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
          for key <- ~w(input output error),
              do: declaration[key <> "_type"] || ["entity", declaration[key]]

        entities = reachable(schema["entities"], referenced(roots), MapSet.new())

        %{
          "format_version" => 9,
          "module" => schema["module"],
          "operations" => [declaration],
          "entities" => entities
        }
    end
  end

  @doc "Captures only the named operations/commands and their reachable types. UI props remain its component input."
  def select(owner, names) do
    schema = definition(owner)
    names = Enum.map(names, &to_string/1)
    available = Enum.map(schema["operations"] ++ schema["commands"], & &1["name"])
    unknown = names -- available

    if unknown != [],
      do: raise(ArgumentError, "unknown requirements #{inspect(unknown)} in #{schema["module"]}")

    schema
    |> Map.update!("operations", &Enum.filter(&1, fn item -> item["name"] in names end))
    |> Map.update!("commands", &Enum.filter(&1, fn item -> item["name"] in names end))
    |> Map.put("notifications", [])
    |> then(fn selected ->
      roots =
        Enum.flat_map(selected["operations"], fn operation ->
          for key <- ~w(input output error),
              do: operation[key <> "_type"] || ["entity", operation[key]]
        end)

      roots =
        roots ++
          Enum.map(selected["commands"], & &1["payload"]) ++
          Enum.map(selected["props"], & &1["type"])

      Map.put(selected, "entities", type_entities(roots, schema["entities"]))
    end)
  end

  @doc "Captures a notification without depending on the provider's operations or other events."
  def notification(owner, name) do
    schema = definition(owner)

    event =
      Enum.find(schema["notifications"], &(&1["name"] == to_string(name))) ||
        raise ArgumentError, "unknown notification #{schema["module"]}.#{name}"

    schema
    |> Map.merge(%{
      "operations" => [],
      "commands" => [],
      "props" => [],
      "slots" => [],
      "notifications" => [event],
      "entities" => type_entities(event["payload"], schema["entities"])
    })
  end

  @doc "Selects the entity graph reachable from a DomainContract type."
  def type_entities(type, entities), do: reachable(entities, referenced(type), MapSet.new())

  defp reachable(entities, names, seen) do
    wanted = MapSet.difference(names, seen)
    selected = Enum.filter(entities, &MapSet.member?(wanted, &1["name"]))

    if selected == [],
      do: [],
      else: selected ++ reachable(entities, referenced(selected), MapSet.union(seen, wanted))
  end

  defp referenced([kind, name]) when kind in ~w(entity), do: MapSet.new([name])
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
        Map.update(result, key, [], &Enum.map(&1, fn item -> Map.delete(item, "description") end))
      end)
    end)
  end
end

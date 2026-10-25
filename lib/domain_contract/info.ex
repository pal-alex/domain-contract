defmodule DomainContract.Info do
  @moduledoc "Canonical, source-independent public contract metadata."
  def contract(module) when is_atom(module) do
    if function_exported?(module, :__contract__, 0),
      do: module.__contract__(),
      else: DomainContract.Reference.compiled(module)
  end

  def contract(%DomainContract.Domain{} = owner) do
    owner
    |> Map.from_struct()
    |> Map.drop([:__spark_metadata__])
    |> Map.update!(:module, &to_string/1)
    |> Map.update!(:operations, &named/1)
    |> Map.update!(:entities, &named/1)
    |> Map.update!(:consumes, fn refs ->
      refs
      |> Enum.map(fn ref ->
        %{
          module: to_string(ref.module),
          optional: ref.optional,
          schema: DomainContract.Schemas.id(ref.definition)
        }
      end)
      |> Enum.sort_by(& &1.module)
    end)
    |> Map.update!(:subscriptions, fn refs ->
      refs
      |> Enum.map(fn ref ->
        %{
          module: to_string(ref.module),
          name: ref.name,
          schema: DomainContract.Schemas.id(ref.definition)
        }
      end)
      |> Enum.sort_by(&{&1.module, &1.name})
    end)
    |> Map.update!(:commands, &named/1)
    |> Map.update!(:notifications, &named/1)
    |> Map.put(
      :schemas,
      Map.new(owner.consumes ++ owner.subscriptions, fn reference ->
        {DomainContract.Schemas.id(reference.definition),
         DomainContract.Schemas.definition(reference.definition)}
      end)
    )
    |> Map.put(:format_version, 8)
    |> canonical()
    |> then(fn artifact ->
      Map.update!(artifact, "schemas", &Map.delete(&1, DomainContract.Schemas.id(artifact)))
    end)
    |> then(&Map.put(&1, "digest", DomainContract.Reference.digest(&1)))
  end

  def canonical(module) when is_atom(module), do: contract(module)
  def canonical(%{"format_version" => 8} = map), do: map
  def canonical(map), do: map |> encode() |> Jason.decode!()
  def normalize(map), do: map |> encode() |> Jason.decode!()
  def json(source), do: source |> canonical() |> encode()
  def encode(value), do: value |> ordered() |> Jason.encode!(pretty: true)
  defp named(items), do: items |> Enum.map(&plain/1) |> Enum.sort_by(& &1.name)

  defp plain(%_{} = struct),
    do:
      struct
      |> Map.from_struct()
      |> Map.drop([:__spark_metadata__, :module, :definition, :inputs, :outputs])
      |> Map.new(fn {k, v} -> {k, plain(v)} end)

  defp plain(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value
  defp ordered(%_{} = struct), do: struct |> Map.from_struct() |> ordered()

  defp ordered(map) when is_map(map),
    do:
      map
      |> Enum.map(fn {k, v} -> {to_string(k), ordered(v)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Jason.OrderedObject.new()

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)

  defp ordered({:enum, values}) do
    [
      "enum",
      values
      |> Enum.map(fn
        atom when is_atom(atom) and atom not in [true, false, nil] ->
          ["atom", Atom.to_string(atom)]

        value ->
          value
      end)
      |> Enum.sort_by(&encode/1)
    ]
  end

  defp ordered(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> ordered()

  defp ordered(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp ordered(value), do: value
  @doc "Compact immutable invocation requirements, without the provider schema graph."
  def binding(owner) do
    owner = canonical(owner)

    owner
    |> Map.take(~w(format_version module version consumes subscriptions))
    |> Map.put("schema", DomainContract.Schemas.id(owner))
  end

  @spec declaration(String.t(), [map()]) :: map()
  def declaration(module, references, schemas \\ %{}) do
    consumes =
      for reference <- merge_references(references) do
        %{
          module: reference["module"],
          optional: reference["optional"],
          definition: DomainContract.Reference.definition(reference, schemas)
        }
      end

    contract(%DomainContract.Domain{
      module: module,
      version: 1,
      responsibility: "Runtime-owned trusted invocation binding for checked owner requirements.",
      consumes: consumes
    })
  end

  defp merge_references(references) do
    references
    |> Enum.group_by(& &1["module"])
    |> Enum.map(fn {module, refs} ->
      definitions = Enum.uniq_by(refs, & &1["schema"])

      if length(definitions) != 1,
        do: raise(ArgumentError, "conflicting retained requirements for #{module}")

      Map.put(hd(refs), "optional", Enum.all?(refs, & &1["optional"]))
    end)
    |> Enum.sort_by(& &1["module"])
  end
end

defmodule DomainContract.Info do
  @moduledoc """
  Deterministic export of the normative domain contract, including API structure and
  behavioral descriptions. Source locations stay in Spark, outside this representation.
  Exporting a contract does not verify that an implementation satisfies its guarantees.
  """
  alias Spark.Dsl.Extension

  @doc "Returns structure and descriptions, with named lists sorted independently of declaration order."
  def contract(module) do
    [domain] = Extension.get_entities(module, [:contract])
    entities = domain.entities |> Enum.map(&entity/1) |> Enum.sort_by(& &1.name)

    result = %{
      format_version: format_version(entities),
      domain: domain.name,
      description: domain.description,
      interfaces:
        domain.interfaces |> Enum.map(&interface/1) |> Enum.sort_by(&{&1.kind, &1.name}),
      entities: entities
    }

    if domain.consumes == [] do
      result
    else
      Map.merge(result, %{
        format_version: 3,
        consumes: domain.consumes |> Enum.map(&interface/1) |> Enum.sort_by(&{&1.kind, &1.name})
      })
    end
  end

  @doc "Canonical JSON, including sorted object keys, suitable for saved evidence and later diffs."
  def json(module), do: module |> contract() |> ordered() |> Jason.encode!(pretty: true)

  defp interface(interface) do
    interface
    |> Map.take([:kind, :name, :version, :description])
    |> Map.put(
      :operations,
      interface.operations
      |> Enum.map(&Map.take(&1, [:name, :input, :output, :description, :optional_output]))
      |> Enum.sort_by(& &1.name)
    )
  end

  defp entity(entity) do
    entity
    |> Map.take([:name, :description])
    |> Map.put(
      :fields,
      entity.fields
      |> Enum.map(&field/1)
      |> Enum.sort_by(& &1.name)
    )
  end

  defp field(field) do
    field
    |> Map.take([:name, :type, :optional, :description])
    |> Map.update!(:type, &canonical_type/1)
  end

  defp canonical_type({:enum, values}), do: {:enum, Enum.sort(values)}

  defp canonical_type({:variant, choices}),
    do: {:variant, Map.new(choices, fn {tag, type} -> {tag, canonical_type(type)} end)}

  defp canonical_type({container, type}) when container in [:list, :dictionary],
    do: {container, canonical_type(type)}

  defp canonical_type(type), do: type

  # Old declarations retain byte-for-byte v1 exports. Readers must explicitly
  # support v2 before consuming enum, variant or JSON scalar declarations.
  defp format_version(entities) do
    if Enum.any?(entities, fn entity -> Enum.any?(entity.fields, &extended_type?(&1.type)) end),
      do: 2,
      else: 1
  end

  defp extended_type?(:json_scalar), do: true
  defp extended_type?({kind, _}) when kind in [:enum, :variant], do: true

  defp extended_type?({container, type}) when container in [:list, :dictionary],
    do: extended_type?(type)

  defp extended_type?(_type), do: false

  defp ordered(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), ordered(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> ordered()
  defp ordered(value), do: value
end

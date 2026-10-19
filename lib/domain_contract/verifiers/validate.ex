defmodule DomainContract.Verifiers.Validate do
  @moduledoc false
  alias Spark.Dsl.Entity
  alias Spark.Error.DslError
  use Spark.Dsl.Verifier
  import Spark.Dsl.Verifier, only: [get_entities: 2, get_persisted: 2]

  @primitives [:string, :integer, :float, :boolean, :datetime, :map, :opaque, :json_scalar, :null]

  @impl true
  def verify(dsl) do
    case get_entities(dsl, [:contract]) do
      [domain] ->
        errors = domain_errors(dsl, domain)
        if errors == [], do: :ok, else: {:error, hd(errors)}

      domains ->
        {:error,
         error(dsl, List.last(domains), [:domain], "expected exactly one domain declaration")}
    end
  end

  defp domain_errors(dsl, domain) do
    path = [:domain, domain.name]
    names = MapSet.new(domain.entities, & &1.name)

    duplicates(dsl, domain.entities, path ++ [:entity], & &1.name) ++
      duplicates(dsl, domain.interfaces, path ++ [:interface], &{&1.kind, &1.name}) ++
      duplicates(dsl, domain.consumes, path ++ [:consumes], & &1.name) ++
      duplicates(
        dsl,
        domain.interfaces ++ domain.implements,
        path ++ [:implements],
        &{to_string(&1.kind), &1.name}
      ) ++
      Enum.flat_map(domain.entities, &entity_errors(dsl, &1, names, path)) ++
      Enum.flat_map(domain.interfaces, &interface_errors(dsl, &1, names, path))
  end

  defp entity_errors(dsl, entity, names, parent) do
    path = parent ++ [:entity, entity.name, :field]

    duplicates(dsl, entity.fields, path, & &1.name) ++
      Enum.flat_map(entity.fields, fn field ->
        if valid_type?(field.type, names) do
          []
        else
          [
            error(
              dsl,
              field,
              path ++ [field.name],
              "invalid field type #{inspect(field.type)}",
              :type
            )
          ]
        end
      end)
  end

  defp interface_errors(dsl, interface, names, parent) do
    path = parent ++ [:interface, interface.kind, interface.name]

    invalid_property = invalid_interface_property(interface)

    declaration =
      if invalid_property do
        [
          error(
            dsl,
            interface,
            path ++ [invalid_property],
            "interface requires an atom kind, non-empty name and positive integer version",
            invalid_property
          )
        ]
      else
        []
      end

    declaration ++
      duplicates(dsl, interface.operations, path ++ [:operation], & &1.name) ++
      Enum.flat_map(interface.operations, fn operation ->
        Enum.flat_map([input: :input_type, output: :output_type], fn {property, type_property} ->
          reference = Map.fetch!(operation, property)
          type = Map.fetch!(operation, type_property)

          valid? =
            if is_nil(type),
              do: MapSet.member?(names, reference),
              else: valid_type?(type, names)

          if valid? do
            []
          else
            [
              error(
                dsl,
                operation,
                path ++ [:operation, operation.name, property],
                if(is_nil(type),
                  do: "operation references unknown entity #{inspect(reference)}",
                  else: "invalid root type #{inspect(type)}"
                ),
                if(is_nil(type), do: property, else: type_property)
              )
            ]
          end
        end)
      end)
  end

  defp invalid_interface_property(interface) do
    cond do
      not is_atom(interface.kind) or interface.kind in [nil, true, false] -> :kind
      not is_binary(interface.name) -> :name
      String.trim(interface.name) == "" -> :name
      not is_integer(interface.version) or interface.version <= 0 -> :version
      true -> nil
    end
  end

  defp valid_type?(type, _names) when type in @primitives, do: true

  defp valid_type?({kind, name}, names) when kind in [:entity, :open_entity],
    do: MapSet.member?(names, name)

  defp valid_type?({:list, type}, names), do: valid_type?(type, names)
  defp valid_type?({:dictionary, type}, names), do: valid_type?(type, names)

  defp valid_type?({:enum, values}, _names) when is_list(values) and values != [] do
    Enum.all?(values, &enum_value?/1) and length(Enum.uniq(values)) == length(values)
  end

  defp valid_type?({:union, types}, names) when is_list(types) and length(types) >= 2,
    do: Enum.all?(types, &valid_type?(&1, names))

  defp valid_type?({:variant, choices}, names) when is_map(choices) and map_size(choices) > 0 do
    Enum.all?(choices, fn {tag, type} -> nonempty_string?(tag) and valid_type?(type, names) end)
  end

  defp valid_type?(_, _), do: false

  defp enum_value?(value)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp enum_value?(value), do: nonempty_string?(value)

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp duplicates(dsl, items, path, key) do
    {_, errors} =
      Enum.reduce(items, {MapSet.new(), []}, fn item, {seen, errors} ->
        identity = key.(item)

        if MapSet.member?(seen, identity) do
          {seen,
           errors ++
             [
               error(
                 dsl,
                 item,
                 path ++ [item.name],
                 "duplicate #{List.last(path)} #{inspect(identity)}"
               )
             ]}
        else
          {MapSet.put(seen, identity), errors}
        end
      end)

    errors
  end

  defp error(dsl, entity, path, message, property \\ nil) do
    location =
      if entity do
        (property && Entity.property_anno(entity, property)) ||
          Entity.anno(entity)
      else
        :erl_anno.set_file(to_charlist(get_persisted(dsl, :file)), :erl_anno.new(1))
      end

    DslError.exception(
      module: get_persisted(dsl, :module),
      path: path,
      message: message,
      location: location
    )
  end
end

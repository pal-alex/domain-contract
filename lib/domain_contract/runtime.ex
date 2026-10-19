defmodule DomainContract.Runtime do
  @moduledoc """
  Validates declared input/output structure without accessing opaque values.

  Descriptions remain normative behavioral rules for implementations and callers;
  this validator does not interpret or enforce them. A successful structural check
  does not prove ownership, idempotency, lifecycle or other behavioral guarantees.
  """
  alias DomainContract.Info

  def input(source, operation, value), do: validate(source, operation, :input, value)
  def output(source, operation, value), do: validate(source, operation, :output, value)

  def input(source, name, operation, value),
    do: validate_interface(source, name, operation, :input, value)

  def output(source, name, operation, value),
    do: validate_interface(source, name, operation, :output, value)

  def dependency(consumer, name) do
    contract = Info.canonical(consumer)

    case Enum.filter(contract["consumes"] || [], &(&1["name"] == name)) do
      [reference] -> {:ok, reference}
      [] -> {:error, {:invalid_contract, :undeclared_dependency}}
      _ -> {:error, {:invalid_contract, :ambiguous_interface}}
    end
  end

  def reference_input(reference, operation, value),
    do: validate_reference(reference, operation, :input, value)

  def reference_output(reference, operation, value),
    do: validate_reference(reference, operation, :output, value)

  defp validate_reference(reference, operation, direction, value) do
    definition = reference["definition"]

    if is_map(definition) and is_map(definition["interface"]) and is_list(definition["entities"]) do
      declaration = Enum.find(definition["interface"]["operations"], &(&1["name"] == operation))

      case validate_value(definition, declaration, operation, direction, value) do
        {:error, :invalid_operation} -> {:error, {:invalid_contract, :invalid_operation}}
        result -> result
      end
    else
      {:error, {:invalid_contract, :invalid_reference}}
    end
  end

  defp validate_interface(source, name, operation, direction, value) do
    contract = Info.canonical(source)

    interfaces =
      contract["interfaces"] ++
        Enum.map(contract["implements"] || [], & &1["definition"]["interface"])

    case Enum.filter(interfaces, &(&1["name"] == name)) do
      [interface] ->
        case Enum.find(contract["implements"] || [], &(&1["name"] == name)) do
          nil ->
            validate_value(
              contract,
              Enum.find(interface["operations"], &(&1["name"] == operation)),
              operation,
              direction,
              value
            )

          reference ->
            validate_reference(reference, operation, direction, value)
        end

      [] ->
        {:error, {:invalid_contract, :invalid_interface}}

      _ ->
        {:error, {:invalid_contract, :ambiguous_interface}}
    end
  end

  defp validate(source, operation, direction, value) do
    contract = Info.canonical(source)

    matches =
      contract["interfaces"]
      |> Enum.flat_map(& &1["operations"])
      |> Enum.filter(&(&1["name"] == operation))

    declaration =
      case matches do
        [declaration] -> declaration
        [] -> nil
        _ -> :ambiguous
      end

    validate_value(contract, declaration, operation, direction, value)
  end

  defp validate_value(contract, declaration, operation, direction, value) do
    entities = Map.new(contract["entities"], &{&1["name"], &1})

    cond do
      is_nil(declaration) ->
        {:error, :invalid_operation}

      declaration == :ambiguous ->
        {:error, :ambiguous_operation}

      direction == :output and declaration["optional_output"] and is_nil(value) ->
        :ok

      true ->
        check(["entity", Map.fetch!(declaration, to_string(direction))], value, entities, [
          operation,
          direction
        ])
    end
  end

  defp check("opaque", _value, _entities, _path), do: :ok
  defp check("string", value, _, _) when is_binary(value), do: :ok
  defp check("integer", value, _, _) when is_integer(value), do: :ok
  defp check("float", value, _, _) when is_number(value), do: :ok
  defp check("boolean", value, _, _) when is_boolean(value), do: :ok

  defp check("json_scalar", value, _, _)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
       do: :ok

  defp check(["enum", values], value, _, path) do
    if value in values, do: :ok, else: invalid(path)
  end

  defp check(["variant", choices], value, entities, path) when is_map(value) do
    cond do
      Enum.any?(Map.keys(value), &(&1 not in ["type", "data"])) ->
        invalid(path ++ [:unknown_field])

      not Map.has_key?(choices, value["type"]) ->
        invalid(path ++ ["type"])

      not Map.has_key?(value, "data") ->
        invalid(path ++ ["data"])

      true ->
        check(Map.fetch!(choices, value["type"]), value["data"], entities, path ++ ["data"])
    end
  end

  defp check("datetime", value, _, path) when is_binary(value) do
    if match?({:ok, _, _}, DateTime.from_iso8601(value)), do: :ok, else: invalid(path)
  end

  defp check("map", value, _, _) when is_map(value), do: :ok

  defp check(["list", type], values, entities, path) when is_list(values),
    do: each(values, &check(type, &1, entities, path))

  defp check(["dictionary", type], values, entities, path) when is_map(values) do
    each(values, fn {key, value} ->
      if is_binary(key), do: check(type, value, entities, path ++ [key]), else: invalid(path)
    end)
  end

  defp check(["entity", name], value, entities, path)
       when is_map(value) do
    fields = entities[name]["fields"]
    keys = Enum.map(fields, & &1["name"])

    if Enum.all?(Map.keys(value), &(&1 in keys)) do
      each(fields, &field(&1, value, entities, path))
    else
      invalid(path ++ [:unknown_field])
    end
  end

  defp check(_, _, _, path), do: invalid(path)

  defp field(field, value, entities, path) do
    key = field["name"]

    cond do
      field["optional"] and is_nil(value[key]) -> :ok
      not Map.has_key?(value, key) -> invalid(path ++ [key])
      true -> check(field["type"], value[key], entities, path ++ [key])
    end
  end

  defp each(items, check),
    do:
      Enum.reduce_while(items, :ok, fn item, _ ->
        case check.(item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

  defp invalid(path), do: {:error, {:invalid_contract, path}}
end

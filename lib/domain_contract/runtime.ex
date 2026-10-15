defmodule DomainContract.Runtime do
  @moduledoc """
  Validates declared input/output structure without accessing opaque values.

  Descriptions remain normative behavioral rules for implementations and callers;
  this validator does not interpret or enforce them. A successful structural check
  does not prove ownership, idempotency, lifecycle or other behavioral guarantees.
  """
  alias DomainContract.Info

  def input(module, operation, value), do: validate(module, operation, :input, value)
  def output(module, operation, value), do: validate(module, operation, :output, value)

  def consumer_input(module, identity, operation, value),
    do: validate_consumer(module, identity, operation, :input, value)

  def consumer_output(module, identity, operation, value),
    do: validate_consumer(module, identity, operation, :output, value)

  defp validate_consumer(module, {kind, name}, operation, direction, value) do
    contract = Info.contract(module)

    matches =
      for interface <- Map.get(contract, :consumes, []),
          interface.kind == kind and interface.name == name,
          declaration <- interface.operations,
          Atom.to_string(declaration.name) == operation,
          do: declaration

    declaration = List.first(matches)
    validate_value(contract, declaration, operation, direction, value, direction == :output)
  end

  defp validate(module, operation, direction, value) do
    contract = Info.contract(module)

    declaration = declaration(contract, operation)

    validate_value(contract, declaration, operation, direction, value, false)
  end

  defp validate_value(contract, declaration, operation, direction, value, projection) do
    entities = {Map.new(contract.entities, &{&1.name, &1}), projection}

    cond do
      is_nil(declaration) ->
        {:error, :invalid_operation}

      declaration == :ambiguous ->
        {:error, :ambiguous_operation}

      direction == :output and declaration.optional_output and is_nil(value) ->
        :ok

      true ->
        check({:entity, Map.fetch!(declaration, direction)}, value, entities, [
          operation,
          direction
        ])
    end
  end

  defp declaration(contract, operation) do
    contract.interfaces
    |> Enum.flat_map(& &1.operations)
    |> Enum.filter(&(Atom.to_string(&1.name) == operation))
    |> case do
      [declaration] -> declaration
      [] -> nil
      _ -> :ambiguous
    end
  end

  defp check(:opaque, _value, _entities, _path), do: :ok
  defp check(:string, value, _, _) when is_binary(value), do: :ok
  defp check(:integer, value, _, _) when is_integer(value), do: :ok
  defp check(:float, value, _, _) when is_number(value), do: :ok
  defp check(:boolean, value, _, _) when is_boolean(value), do: :ok

  defp check(:json_scalar, value, _, _)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
       do: :ok

  defp check({:enum, values}, value, _, path) do
    if value in values, do: :ok, else: invalid(path)
  end

  defp check({:variant, choices}, value, entities, path) when is_map(value) do
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

  defp check(:datetime, value, _, path) when is_binary(value) do
    if match?({:ok, _, _}, DateTime.from_iso8601(value)), do: :ok, else: invalid(path)
  end

  defp check(:map, value, _, _) when is_map(value), do: :ok

  defp check({:list, type}, values, entities, path) when is_list(values),
    do: each(values, &check(type, &1, entities, path))

  defp check({:dictionary, type}, values, entities, path) when is_map(values) do
    each(values, fn {key, value} ->
      if is_binary(key), do: check(type, value, entities, path ++ [key]), else: invalid(path)
    end)
  end

  defp check({:entity, name}, value, {definitions, projection} = entities, path)
       when is_map(value) do
    fields = definitions[name].fields
    keys = Enum.map(fields, &Atom.to_string(&1.name))

    if projection or Enum.all?(Map.keys(value), &(&1 in keys)) do
      each(fields, &field(&1, value, entities, path))
    else
      invalid(path ++ [:unknown_field])
    end
  end

  defp check(_, _, _, path), do: invalid(path)

  defp field(field, value, entities, path) do
    key = Atom.to_string(field.name)

    cond do
      field.optional and is_nil(value[key]) -> :ok
      not Map.has_key?(value, key) -> invalid(path ++ [key])
      true -> check(field.type, value[key], entities, path ++ [key])
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

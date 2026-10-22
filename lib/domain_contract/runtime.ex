defmodule DomainContract.Runtime do
  @moduledoc """
  Validates declared input/output structure without accessing opaque values.

  Descriptions remain normative behavioral rules for implementations and callers;
  this validator does not interpret or enforce them. A successful structural check
  does not prove ownership, idempotency, lifecycle or other behavioral guarantees.
  """
  alias DomainContract.Info

  def invoke(owner, target, operation, input, context) when is_atom(target) do
    with {:ok, consumer, binding} <- consumer(owner, context),
         {:ok, reference} <- declared_dependency(consumer, target),
         {:ok, expected} <- expected_definition(consumer, reference, binding),
         {:ok, declaration} <- operation(expected, operation),
         entities = Map.new(expected["entities"], &{&1["name"], &1}),
         :ok <- value(declaration, :input, input, entities),
         {:ok, call} <- entry(target, reference) do
      result = call.(to_string(operation), input, context)

      case result do
        {:ok, output} ->
          with :ok <- value(declaration, :output, output, entities), do: {:ok, output}

        {:error, _} = error ->
          error

        _ ->
          {:error, {:invalid_contract, :invalid_result}}
      end
    end
  end

  def invoke(_, _, _, _, _), do: {:error, {:invalid_contract, :invocation}}

  # The local capture and schema come from one code generation. A concurrent
  # replacement cannot redirect this call to unchecked new code.
  defp entry(target, reference) do
    if Code.ensure_loaded?(target) and function_exported?(target, :__contract_entry__, 0) do
      {schema, call} = target.__contract_entry__()

      if DomainContract.SchemaStore.approved?(reference["schema"], schema),
        do: {:ok, call},
        else: {:error, {:invalid_contract, :provider_mismatch}}
    else
      {:error, {:unavailable, target}}
    end
  end

  defp consumer(owner, nil) when is_atom(owner), do: {:ok, Info.canonical(owner), nil}

  defp consumer(owner, nil) do
    with :ok <- DomainContract.Artifact.validate(owner),
         do: {:ok, Info.canonical(owner), nil}
  end

  defp consumer(owner, context) do
    with {:ok, binding} <- DomainContract.Context.fetch(context),
         true <- not is_nil(binding.caller),
         true <-
           owner == :context or
             binding.consumer["module"] ==
               if(is_atom(owner), do: Atom.to_string(owner), else: owner) do
      {:ok, binding.consumer, binding}
    else
      {:error, _} = error -> error
      _ -> {:error, {:invalid_contract, :caller_context}}
    end
  end

  def input(source, operation, value), do: validate(source, operation, :input, value)
  def output(source, operation, value), do: validate(source, operation, :output, value)

  def dependency(%{"format_version" => version}, _module) when version != 8,
    do: {:error, {:invalid_contract, :format_version}}

  def dependency(consumer, module) do
    consumer = canonical(consumer)

    declared_dependency(consumer, module)
  end

  defp declared_dependency(%{"format_version" => version}, _module) when version != 8,
    do: {:error, {:invalid_contract, :format_version}}

  defp declared_dependency(consumer, module) do
    name = if is_atom(module), do: Atom.to_string(module), else: module

    case Enum.filter(consumer["consumes"] || [], &(&1["module"] == name)) do
      [reference] -> {:ok, reference}
      [] -> {:error, {:invalid_contract, :undeclared_dependency}}
      _ -> {:error, {:invalid_contract, :ambiguous_contract}}
    end
  end

  defp expected_definition(consumer, reference, nil), do: {:ok, definition(consumer, reference)}

  defp expected_definition(_consumer, reference, _binding),
    do: DomainContract.SchemaStore.fetch(reference["schema"])

  # A compiled local owner carries its requirements inline. Bound platform
  # consumers use schemas owned by the selected installation.
  defp definition(%{"module" => module, "operations" => _} = consumer, %{"module" => module}),
    do: DomainContract.Schemas.definition(consumer)

  defp definition(consumer, reference),
    do: DomainContract.Reference.definition(reference, Map.get(consumer, "schemas", %{}))

  def reference_input(reference, operation, value),
    do: input(DomainContract.Reference.definition(reference), operation, value)

  def reference_output(reference, operation, value),
    do: output(DomainContract.Reference.definition(reference), operation, value)

  def validate_type(type, value, entities \\ [], path \\ []),
    do:
      check(
        type |> Info.encode() |> Jason.decode!(),
        value,
        Map.new(entities, &{&1["name"], &1}),
        path
      )

  # Captured compiler metadata is already canonical. Invocation must not rescan
  # build inputs or serialize the complete dependency graph for each value.
  defp canonical(%{"format_version" => 8, "module" => module} = contract) when is_binary(module),
    do: contract

  defp canonical(source), do: Info.canonical(source)

  defp validate(source, operation, direction, value) do
    contract = canonical(source)

    with {:ok, declaration} <- operation(contract, operation),
         do:
           value(declaration, direction, value, Map.new(contract["entities"], &{&1["name"], &1}))
  end

  defp operation(contract, name) do
    case Enum.find(contract["operations"], &(&1["name"] == to_string(name))) do
      nil -> {:error, {:invalid_contract, :invalid_operation}}
      declaration -> {:ok, declaration}
    end
  end

  defp value(declaration, direction, value, entities) do
    if direction == :output and declaration["optional_output"] and is_nil(value) do
      :ok
    else
      key = to_string(direction)
      type = declaration[key <> "_type"] || ["entity", declaration[key]]
      check(type, value, entities, [declaration["name"], direction])
    end
  end

  defp check(["struct", name], %{__struct__: module}, _, _) when is_atom(module) do
    if Atom.to_string(module) == name,
      do: :ok,
      else: {:error, {:invalid_contract, :invalid_struct}}
  end

  defp check("any", _value, _entities, _path), do: :ok
  defp check("atom", value, _, _) when is_atom(value), do: :ok
  defp check("list", value, _, _) when is_list(value), do: :ok
  defp check("global", value, _, _) when is_map(value), do: :ok
  defp check(["nullable", _], nil, _, _), do: :ok
  defp check(["nullable", type], value, entities, path), do: check(type, value, entities, path)

  defp check(fields, value, entities, path) when is_map(fields) and is_map(value) do
    original_size = map_size(value)
    value = normalize_keys(value)

    if map_size(value) == original_size and
         Enum.sort(Map.keys(fields)) == Enum.sort(Map.keys(value)),
       do: each(fields, fn {key, type} -> check(type, value[key], entities, path ++ [key]) end),
       else: invalid(path ++ [:unknown_or_missing_field])
  end

  defp check("opaque", _value, _entities, _path), do: :ok
  defp check("null", nil, _entities, _path), do: :ok
  defp check("string", value, _, _) when is_binary(value), do: :ok
  defp check("integer", value, _, _) when is_integer(value), do: :ok
  defp check("float", value, _, _) when is_number(value), do: :ok
  defp check("boolean", value, _, _) when is_boolean(value), do: :ok

  defp check("json_scalar", value, _, _)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value),
       do: :ok

  defp check(["enum", values], value, _, path) do
    encoded =
      if is_atom(value) and value not in [true, false, nil],
        do: ["atom", Atom.to_string(value)],
        else: value

    if Enum.any?(values, &(&1 === encoded)), do: :ok, else: invalid(path)
  end

  defp check(["union", types], value, entities, path) do
    if Enum.any?(types, &(check(&1, value, entities, path) == :ok)),
      do: :ok,
      else: invalid(path)
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

  defp check([kind, name], value, entities, path)
       when kind in ["entity", "open_entity"] and is_map(value) do
    original = value
    value = normalize_keys(value)
    fields = entities[name]["fields"]
    keys = Enum.map(fields, & &1["name"])

    valid_keys? =
      case kind do
        "entity" ->
          Enum.all?(Map.keys(value), &(&1 in keys))

        "open_entity" ->
          Enum.all?(Map.keys(original), fn key ->
            is_binary(key) or (is_atom(key) and Atom.to_string(key) in keys)
          end)
      end

    if valid_keys? and map_size(original) == map_size(value) do
      each(fields, &field(&1, value, entities, path))
    else
      invalid(path ++ [:unknown_field])
    end
  end

  defp check(_, _, _, path), do: invalid(path)

  defp field(field, value, entities, path) do
    key = field["name"]

    cond do
      field["optional"] and not Map.has_key?(value, key) -> :ok
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

  defp normalize_keys(value),
    do:
      Map.new(value, fn {key, v} -> {if(is_atom(key), do: Atom.to_string(key), else: key), v} end)

  defp invalid(path), do: {:error, {:invalid_contract, path}}
end

defmodule DomainContract.Runtime do
  @moduledoc """
  Validates declared input/output structure including error values and the exact key representation.

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
         {:ok, call} <- entry(target, reference, expected, binding) do
      result = call.(to_string(operation), input, context)

      case result do
        {:ok, output} ->
          with :ok <- value(declaration, :output, output, entities), do: {:ok, output}

        {:error, reason} ->
          with :ok <- value(declaration, :error, reason, entities), do: {:error, reason}

        _ ->
          {:error, {:invalid_contract, :invalid_result}}
      end
    end
  rescue
    error in DomainContract.InvocationError -> {:error, error.reason}
  end

  def invoke(_, _, _, _, _), do: {:error, {:invalid_contract, :invocation}}

  # The local capture and schema come from one code generation. A concurrent
  # replacement cannot redirect this call to unchecked new code.
  defp entry(target, reference, expected, binding) do
    if Code.ensure_loaded?(target) and function_exported?(target, :__contract_entry__, 0) do
      {schema, call} = target.__contract_entry__()

      if approved?(target, reference, schema, expected, binding),
        do: {:ok, call},
        else: {:error, {:invalid_contract, :provider_mismatch}}
    else
      {:error, {:unavailable, target}}
    end
  end

  defp approved?(target, reference, schema, expected, nil) do
    if reference["schema"] == schema do
      true
    else
      provider = target.__contract__()

      DomainContract.Schemas.id(provider) == schema and
        DomainContract.Compatibility.satisfies(provider, expected) == :ok
    end
  end

  defp approved?(_target, reference, schema, _expected, _binding),
    do: DomainContract.SchemaStore.approve(reference["schema"], schema) == :ok

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

  def dependency(%{"format_version" => version}, _module) when version != 9,
    do: {:error, {:invalid_contract, :format_version}}

  def dependency(consumer, module) do
    consumer = canonical(consumer)

    declared_dependency(consumer, module)
  end

  defp declared_dependency(%{"format_version" => version}, _module) when version != 9,
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
  defp definition(
         %{"module" => module, "operations" => _} = consumer,
         %{"module" => module} = reference
       ) do
    Map.get_lazy(Map.get(consumer, "schemas", %{}), reference["schema"], fn ->
      DomainContract.Schemas.definition(consumer)
    end)
  end

  defp definition(consumer, reference),
    do: DomainContract.Reference.definition(reference, Map.get(consumer, "schemas", %{}))

  def reference_input(reference, operation, value),
    do: input(DomainContract.Reference.definition(reference), operation, value)

  def reference_output(reference, operation, value),
    do: output(DomainContract.Reference.definition(reference), operation, value)

  def validate_type(type, value, entities \\ [], path \\ []),
    do:
      check(
        type |> DomainContract.Type.encode() |> Info.encode() |> Jason.decode!(),
        value,
        Map.new(entities, &{&1["name"], &1}),
        path
      )

  # Captured compiler metadata is already canonical. Invocation must not rescan
  # build inputs or serialize the complete dependency graph for each value.
  defp canonical(%{"format_version" => 9, "module" => module} = contract) when is_binary(module),
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

  defp check(["struct", name, fields], %{__struct__: module} = value, entities, path)
       when is_atom(module) do
    with true <- Atom.to_string(module) == name,
         :ok <- check(fields, Map.delete(value, :__struct__), entities, path),
         true <- calendar_valid?(value) do
      :ok
    else
      _ -> invalid(path)
    end
  end

  defp check("atom", value, _, _) when is_atom(value), do: :ok
  defp check(["nullable", _], nil, _, _), do: :ok
  defp check(["nullable", type], value, entities, path), do: check(type, value, entities, path)

  defp check(["map", mode, fields], value, entities, path) when is_map(value) do
    with {:ok, indexed} <- keys(value, mode),
         true <- Enum.sort(Map.keys(fields)) == Enum.sort(Map.keys(indexed)) do
      each(fields, fn {key, type} -> check(type, indexed[key], entities, path ++ [key]) end)
    else
      _ -> invalid(path ++ [:unknown_or_missing_field])
    end
  end

  defp check(["tuple", types], value, entities, path) when is_tuple(value) do
    if tuple_size(value) == length(types),
      do:
        each(Enum.zip(types, Tuple.to_list(value)), fn {type, item} ->
          check(type, item, entities, path)
        end),
      else: invalid(path)
  end

  defp check("null", nil, _entities, _path), do: :ok
  defp check("binary", value, _, _) when is_binary(value), do: :ok

  defp check("string", value, _, path) when is_binary(value),
    do: if(String.valid?(value), do: :ok, else: invalid(path))

  defp check("json", value, _, path), do: if(json?(value), do: :ok, else: invalid(path))
  defp check("integer", value, _, _) when is_integer(value), do: :ok
  defp check("float", value, _, _) when is_number(value), do: :ok
  defp check("boolean", value, _, _) when is_boolean(value), do: :ok

  defp check("json_scalar", value, _, _)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: :ok

  defp check("json_scalar", value, entities, path) when is_binary(value),
    do: check("string", value, entities, path)

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

  defp check(["list", type], values, entities, path) when is_list(values),
    do: each(values, &check(type, &1, entities, path))

  defp check(["dictionary", type], values, entities, path)
       when is_map(values) and not is_struct(values) do
    each(values, fn {key, value} ->
      if is_binary(key), do: check(type, value, entities, path ++ [key]), else: invalid(path)
    end)
  end

  defp check(["entity", name], value, entities, path) when is_map(value) do
    entity = Map.fetch!(entities, name)
    fields = entity["fields"]
    names = Enum.map(fields, & &1["name"])

    with {:ok, indexed} <- keys(value, entity["keys"]),
         true <- Enum.all?(Map.keys(indexed), &(&1 in names)) do
      each(fields, &field(&1, indexed, entities, path))
    else
      _ -> invalid(path ++ [:unknown_field])
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

  defp keys(value, _) when is_struct(value), do: :error

  defp keys(value, "atoms") do
    if Enum.all?(Map.keys(value), &is_atom/1),
      do: {:ok, Map.new(value, fn {key, v} -> {Atom.to_string(key), v} end)},
      else: :error
  end

  defp keys(value, "strings") do
    if Enum.all?(Map.keys(value), &is_binary/1), do: {:ok, value}, else: :error
  end

  defp calendar_valid?(%{__struct__: module} = value)
       when module in [Date, DateTime, NaiveDateTime, Time] do
    date = module == Time or Calendar.ISO.valid_date?(value.year, value.month, value.day)

    time =
      module == Date or
        Calendar.ISO.valid_time?(value.hour, value.minute, value.second, value.microsecond)

    date and time
  end

  defp calendar_valid?(_), do: true

  defp json?(value) when is_nil(value) or is_boolean(value) or is_number(value), do: true
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  defp json?(value) when is_map(value) and not is_struct(value),
    do:
      Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)

  defp json?(_), do: false

  defp invalid(path), do: {:error, {:invalid_contract, path}}
end

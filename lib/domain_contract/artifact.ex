defmodule DomainContract.Artifact do
  @moduledoc "Validates canonical metadata and inspects BEAM attributes without loading code."
  alias DomainContract.Info

  @primitives ~w(string integer float boolean datetime map opaque json_scalar null atom any list global)
  def from_beam(beam) when is_binary(beam) do
    with {:ok, {module, chunks}} <- :beam_lib.chunks(beam, [:attributes, :exports]) do
      case Keyword.get_values(chunks[:attributes], :domain_contract_artifact) do
        [] ->
          {:error, :not_contract}

        [[artifact]] when is_map(artifact) ->
          if artifact["module"] == Atom.to_string(module) and
               {:__contract__, 0} in chunks[:exports] and validate(artifact) == :ok,
             do: {:ok, artifact},
             else: {:error, :invalid_artifact}

        _ ->
          {:error, :invalid_artifact}
      end
    else
      _ -> {:error, :invalid_beam}
    end
  rescue
    _ -> {:error, :invalid_beam}
  end

  def from_beam(_), do: {:error, :invalid_beam}

  @doc "Reuses checks of exact immutable values only for the duration of this admission."
  def with_validation(function) do
    if Process.get({__MODULE__, :validation}) do
      function.()
    else
      Process.put({__MODULE__, :validation}, %{})

      try do
        function.()
      after
        Process.delete({__MODULE__, :validation})
      end
    end
  end

  @doc """
  Continues admission with exact declarations held by already verified prepared packages.

  Trusted installation adapters use this when handing preparation to another process.
  Never pass unchecked metadata here. Reuse is scoped to the function and keyed by
  complete immutable values, including definitions, edges and owner digests, not IDs.
  """
  def with_prepared(owners, function) do
    with_validation(fn ->
      Enum.each(owners, &remember_prepared/1)
      function.()
    end)
  end

  defp remember_prepared(owner) do
    once(:artifact, owner, fn -> true end)
    once(:definition, DomainContract.Schemas.definition(owner), fn -> true end)

    if is_binary(owner["digest"]),
      do: once(:digest, Map.delete(owner, "digest"), fn -> owner["digest"] end)

    Enum.each(Map.get(owner, "schemas", %{}), fn {id, schema} ->
      remember_prepared(schema)
      once(:digest, DomainContract.Schemas.definition(schema), fn -> id end)
    end)
  end

  defp once(kind, value, function) do
    case Process.get({__MODULE__, :validation}) do
      nil ->
        function.()

      checked ->
        key = {kind, value}

        case Map.fetch(checked, key) do
          {:ok, result} ->
            result

          :error ->
            result = function.()

            Process.put(
              {__MODULE__, :validation},
              Map.put(Process.get({__MODULE__, :validation}), key, result)
            )

            result
        end
    end
  end

  @doc false
  def digest(artifact) do
    value = Map.delete(artifact, "digest")

    once(:digest, value, fn ->
      :crypto.hash(:sha256, Info.encode(value)) |> Base.encode16(case: :lower)
    end)
  end

  def validate(source) do
    with_validation(fn ->
      contract = Info.canonical(source)
      if valid?(contract), do: :ok, else: {:error, :invalid_artifact}
    end)
  rescue
    _ -> {:error, :invalid_artifact}
  end

  defp valid?(c) do
    once(:artifact, c, fn ->
      definition = DomainContract.Schemas.definition(c)

      once(:definition, definition, fn -> definition?(definition) end) and
        schemas?(c) and references?(c) and
        (not Map.has_key?(c, "digest") or c["digest"] == DomainContract.Reference.digest(c))
    end)
  end

  defp definition?(c) do
    c["format_version"] == 8 and not Map.has_key?(c, "schema") and is_binary(c["module"]) and
      String.starts_with?(c["module"], "Elixir.") and
      is_integer(c["version"]) and c["version"] > 0 and c["kind"] in ~w(domain ui) and
      is_binary(c["responsibility"]) and String.trim(c["responsibility"]) != "" and
      is_map(c["metadata"]) and schema?(c)
  end

  defp schemas?(c) do
    schemas = Map.get(c, "schemas", %{})

    is_map(schemas) and
      Enum.all?(schemas, fn {id, schema} ->
        id == DomainContract.Schemas.id(schema) and
          not Map.has_key?(schema, "schemas") and not Map.has_key?(schema, "consumes") and
          valid?(schema)
      end)
  end

  defp references?(c) do
    references = c["consumes"] || []
    subscriptions = c["subscriptions"] || []

    if references == [] and subscriptions == [] do
      true
    else
      index =
        Map.put(
          Map.get(c, "schemas", %{}),
          DomainContract.Schemas.id(c),
          DomainContract.Schemas.definition(c)
        )

      unique?(references, "module") and
        Enum.all?(references, fn ref ->
          is_binary(ref["module"]) and is_boolean(ref["optional"]) and reference?(ref, index)
        end) and
        Enum.all?(subscriptions, fn ref ->
          is_binary(ref["module"]) and is_binary(ref["name"]) and reference?(ref, index) and
            Enum.any?(index[ref["schema"]]["notifications"], &(&1["name"] == ref["name"]))
        end)
    end
  end

  defp reference?(ref, index) do
    definition = index[ref["schema"]]

    is_binary(ref["schema"]) and not Map.has_key?(ref, "definition") and
      is_map(definition) and definition["module"] == ref["module"]
  end

  defp schema?(c) do
    names = Enum.map(c["entities"], & &1["name"])

    unique?(c["entities"], "name") and
      Enum.all?(c["entities"], fn entity ->
        is_binary(entity["name"]) and unique?(entity["fields"], "name") and
          Enum.all?(entity["fields"], fn field ->
            is_binary(field["name"]) and is_boolean(field["optional"]) and
              type?(field["type"], names)
          end)
      end) and unique?(c["operations"], "name") and
      Enum.all?(c["operations"], fn op ->
        is_binary(op["name"]) and is_boolean(op["optional_output"]) and root?(op, "input", names) and
          root?(op, "output", names)
      end) and
      Enum.all?(["commands", "notifications"], fn key ->
        unique?(c[key], "name") and
          Enum.all?(c[key], fn m -> is_binary(m["name"]) and type?(m["payload"], names) end)
      end) and unique?(c["props"], "name") and
      Enum.all?(c["props"], fn prop ->
        is_binary(prop["name"]) and is_boolean(prop["required"]) and type?(prop["type"], names)
      end)
  end

  defp root?(op, side, names),
    do:
      if(is_nil(op[side <> "_type"]),
        do: op[side] in names,
        else: is_nil(op[side]) and type?(op[side <> "_type"], names)
      )

  def type?(type, _) when type in @primitives, do: true

  def type?(["struct", module], _names) when is_binary(module),
    do: String.starts_with?(module, "Elixir.")

  def type?([kind, name], names) when kind in ~w(entity open_entity), do: name in names
  def type?([kind, type], names) when kind in ~w(list dictionary nullable), do: type?(type, names)

  def type?(["enum", values], _) when is_list(values),
    do: values != [] and Enum.uniq(values) == values

  def type?(["union", types], names) when is_list(types),
    do: length(types) >= 2 and Enum.all?(types, &type?(&1, names))

  def type?(["variant", choices], names) when is_map(choices),
    do:
      map_size(choices) > 0 and
        Enum.all?(choices, fn {tag, t} -> is_binary(tag) and type?(t, names) end)

  def type?(fields, names) when is_map(fields),
    do: Enum.all?(fields, fn {key, t} -> is_binary(key) and type?(t, names) end)

  def type?(_, _), do: false

  defp unique?(items, key) when is_list(items),
    do: length(items) == length(Enum.uniq_by(items, & &1[key]))

  defp unique?(_, _), do: false
end

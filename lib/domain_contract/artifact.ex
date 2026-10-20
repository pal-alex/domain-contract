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

  def validate(source) do
    contract = Info.canonical(source)
    if valid?(contract), do: :ok, else: {:error, :invalid_artifact}
  rescue
    _ -> {:error, :invalid_artifact}
  end

  defp valid?(c) do
    c["format_version"] == 7 and is_binary(c["module"]) and
      String.starts_with?(c["module"], "Elixir.") and
      is_integer(c["version"]) and c["version"] > 0 and c["kind"] in ~w(domain ui) and
      is_binary(c["responsibility"]) and String.trim(c["responsibility"]) != "" and
      is_map(c["metadata"]) and schema?(c) and dependencies?(c["consumes"] || []) and
      Enum.all?(c["subscriptions"] || [], fn s ->
        is_binary(s["module"]) and is_binary(s["name"]) and is_map(s["definition"])
      end) and
      (not Map.has_key?(c, "digest") or c["digest"] == DomainContract.Reference.digest(c))
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

  defp dependencies?(refs),
    do:
      unique?(refs, "module") and
        Enum.all?(refs, fn r ->
          is_binary(r["module"]) and is_boolean(r["optional"]) and
            r["definition"]["module"] == r["module"] and valid?(r["definition"])
        end)

  def type?(type, _) when type in @primitives, do: true
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

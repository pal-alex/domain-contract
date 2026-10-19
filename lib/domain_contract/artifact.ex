defmodule DomainContract.Artifact do
  @moduledoc "Validation of canonical contract artifacts before compilation, packaging or activation."
  alias DomainContract.{Info, Reference}
  @primitives ~w(string integer float boolean datetime map opaque json_scalar null)

  @doc """
  Reads a compiled declaration's canonical export without loading its module.

  Returns `{:ok, artifact}`, `{:error, :not_contract}` for a BEAM without an
  export, or `{:error, :invalid_artifact | :invalid_beam}` for malformed data.
  The export includes composed schemas, references and behavioral descriptions.
  Fragments and implementation entry points do not acquire a declaration export.

  This checks packaged data, not its authority. The adapter must establish source
  provenance and compare implementations against independently trusted originals.
  """
  def from_beam(beam) when is_binary(beam) do
    case :beam_lib.chunks(beam, [:attributes, :exports]) do
      {:ok, {_module, chunks}} ->
        read_export(chunks)

      _ ->
        {:error, :invalid_beam}
    end
  rescue
    _ -> {:error, :invalid_beam}
  end

  def from_beam(_beam), do: {:error, :invalid_beam}

  defp read_export(chunks) do
    case Keyword.get_values(chunks[:attributes], :domain_contract_artifact) do
      [] ->
        {:error, :not_contract}

      [[artifact]] when is_map(artifact) ->
        if Map.has_key?(artifact, "interfaces") and
             Enum.all?([{:entities, 1}, {:spark_dsl_config, 0}], &(&1 in chunks[:exports])) and
             validate(artifact) == :ok,
           do: {:ok, artifact},
           else: {:error, :invalid_artifact}

      _ ->
        {:error, :invalid_artifact}
    end
  end

  @doc "Rejects malformed schemas, unresolved types, legacy projections and inconsistent references."
  def validate(source) do
    contract = Info.canonical(source)
    if valid_contract?(contract), do: :ok, else: {:error, :invalid_artifact}
  rescue
    _ -> {:error, :invalid_artifact}
  end

  defp valid_contract?(contract) do
    contract["format_version"] in [1, 2, 4, 5, 6] and
      nonempty?(contract["domain"]) and description?(contract) and
      schema?(contract["interfaces"], contract["entities"]) and
      references?(Map.get(contract, "consumes", []), true) and
      references?(Map.get(contract, "implements", []), false) and
      (contract["format_version"] in [4, 5, 6] or
         (not Map.has_key?(contract, "consumes") and not Map.has_key?(contract, "implements"))) and
      (contract["format_version"] in [5, 6] or not Info.requires_v5?(contract)) and
      (contract["format_version"] == 6 or not Info.requires_v6?(contract)) and
      unique?(
        (contract["interfaces"] || []) ++ (contract["implements"] || []),
        &{&1["kind"], &1["name"]}
      )
  end

  defp schema?(interfaces, entities) when is_list(interfaces) and is_list(entities) do
    names = Enum.map(entities, & &1["name"])

    unique?(entities, & &1["name"]) and
      unique?(interfaces, &{&1["kind"], &1["name"]}) and
      Enum.all?(entities, &entity?(&1, names)) and
      Enum.all?(interfaces, &interface?(&1, names))
  end

  defp schema?(_, _), do: false

  defp entity?(entity, names) do
    nonempty?(entity["name"]) and description?(entity) and is_list(entity["fields"]) and
      unique?(entity["fields"], & &1["name"]) and
      Enum.all?(entity["fields"], fn field ->
        nonempty?(field["name"]) and is_boolean(field["optional"]) and
          description?(field) and type?(field["type"], names)
      end)
  end

  defp interface?(interface, names) do
    identity?(interface) and description?(interface) and is_list(interface["operations"]) and
      unique?(interface["operations"], & &1["name"]) and
      Enum.all?(interface["operations"], fn operation ->
        nonempty?(operation["name"]) and description?(operation) and
          root?(operation, "input", names) and root?(operation, "output", names) and
          is_boolean(operation["optional_output"])
      end)
  end

  defp root?(operation, direction, names) do
    case Map.fetch(operation, direction <> "_type") do
      {:ok, type} -> is_nil(operation[direction]) and type?(type, names)
      :error -> operation[direction] in names
    end
  end

  defp identity?(value) do
    nonempty?(value["kind"]) and nonempty?(value["name"]) and
      is_integer(value["version"]) and value["version"] > 0
  end

  defp references?(references, optional?) when is_list(references) do
    unique?(references, fn reference ->
      if optional?, do: reference["name"], else: {reference["kind"], reference["name"]}
    end) and
      Enum.all?(references, fn reference ->
        definition = reference["definition"]

        identity?(reference) and is_boolean(reference["optional"]) and
          (optional? or not reference["optional"]) and
          Enum.all?(Map.keys(reference), &(&1 in ~w(kind name version optional definition))) and
          Reference.valid?(definition) and
          description?(definition) and
          Enum.all?(~w(kind name version), &(reference[&1] == definition["interface"][&1])) and
          schema?([definition["interface"]], definition["entities"])
      end)
  end

  defp references?(_, _), do: false

  defp type?(type, _) when type in @primitives, do: true
  defp type?([kind, name], names) when kind in ["entity", "open_entity"], do: name in names
  defp type?([kind, type], names) when kind in ~w(list dictionary), do: type?(type, names)

  defp type?(["enum", values], _) when is_list(values),
    do: values != [] and Enum.all?(values, &enum_value?/1) and Enum.uniq(values) == values

  defp type?(["union", types], names) when is_list(types),
    do: length(types) >= 2 and Enum.all?(types, &type?(&1, names))

  defp type?(["variant", choices], names) when is_map(choices),
    do:
      map_size(choices) > 0 and
        Enum.all?(choices, fn {tag, type} -> nonempty?(tag) and type?(type, names) end)

  defp type?(_, _), do: false

  defp enum_value?(value)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp enum_value?(value), do: nonempty?(value)
  defp description?(value), do: is_nil(value["description"]) or is_binary(value["description"])
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp unique?(values, key), do: length(values) == length(Enum.uniq_by(values, key))
end

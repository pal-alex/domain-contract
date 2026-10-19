defmodule DomainContract.Compatibility do
  @moduledoc """
  Checks an exact deployment candidate against authoritative canonical artifacts.

  The second argument is a list of immutable contract exports from the package
  catalog. Definitions declared by candidates are also checked against that catalog.
  References never define new contracts. Optional providers may be absent; present
  providers must implement the exact referenced version and complete definition.
  """
  alias DomainContract.{Artifact, Info, Reference}

  @spec check([module() | map()], [module() | map()]) :: :ok | {:error, [map()]}
  def check(candidates, authorities \\ []) do
    invalid =
      for {source, index} <- Enum.with_index(candidates ++ authorities),
          Artifact.validate(source) != :ok,
          do: %{contract: index, reason: :invalid_artifact}

    if invalid == [], do: check_valid(candidates, authorities), else: {:error, invalid}
  end

  defp check_valid(candidates, authorities) do
    candidates = Enum.map(candidates, &Info.canonical/1)
    authorities = Enum.map(authorities, &Info.canonical/1)
    definitions = Enum.flat_map(authorities ++ candidates, &definitions/1)
    catalog = Enum.group_by(definitions, &key/1)

    providers =
      for candidate <- candidates, reference <- provided(candidate), do: {candidate, reference}

    conflicts =
      for {identity, values} <- catalog,
          length(Enum.uniq(values)) > 1,
          do: %{interface: identity, reason: :conflicting_contract}

    duplicates =
      providers
      |> Enum.group_by(fn {_, reference} -> reference["name"] end)
      |> Enum.flat_map(fn
        {_, [_]} -> []
        {name, _} -> [%{interface: name, reason: :multiple_providers}]
      end)

    errors =
      for candidate <- candidates,
          reference <- (candidate["implements"] || []) ++ (candidate["consumes"] || []),
          reason <- verify_reference(reference, catalog),
          do: %{consumer: candidate["domain"], interface: key(reference), reason: reason}

    dependencies =
      for candidate <- candidates,
          reference <- candidate["consumes"] || [],
          reason <- dependency(reference, providers),
          do: %{consumer: candidate["domain"], interface: key(reference), reason: reason}

    case conflicts ++ duplicates ++ errors ++ dependencies do
      [] -> :ok
      errors -> {:error, Enum.uniq(errors)}
    end
  end

  @doc "Returns the complete public contracts supplied by a declaration."
  def provided(source) do
    contract = Info.canonical(source)
    definitions(contract) ++ (contract["implements"] || [])
  end

  defp definitions(contract) do
    for interface <- contract["interfaces"] do
      %{
        "kind" => interface["kind"],
        "name" => interface["name"],
        "version" => interface["version"],
        "definition" =>
          Reference.snapshot(interface, contract["entities"], contract["description"])
      }
    end
  end

  defp key(reference), do: {reference["kind"], reference["name"], reference["version"]}

  defp verify_reference(reference, catalog) do
    definition = reference["definition"]

    cond do
      not Reference.valid?(definition) ->
        [:invalid_reference]

      Enum.any?(["kind", "name", "version"], &(reference[&1] != definition["interface"][&1])) ->
        [:invalid_reference]

      Map.get(catalog, key(reference), []) == [] ->
        [:unknown_contract]

      Enum.any?(catalog[key(reference)], &(&1["definition"] != definition)) ->
        [:conflicting_contract]

      true ->
        []
    end
  end

  defp dependency(reference, providers) do
    case Enum.filter(providers, fn {_, provider} -> provider["name"] == reference["name"] end) do
      [] ->
        if(reference["optional"] == true, do: [], else: [:missing_provider])

      [{_, provider}] ->
        cond do
          key(provider) != key(reference) -> [:incorrect_version]
          provider["definition"] != reference["definition"] -> [:conflicting_contract]
          true -> []
        end

      _ ->
        []
    end
  end
end

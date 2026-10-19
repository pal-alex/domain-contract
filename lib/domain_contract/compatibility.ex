defmodule DomainContract.Compatibility do
  @moduledoc """
  Checks an exact deployment candidate against authoritative canonical artifacts.

  The second argument is a list of immutable contract exports from the package
  catalog. Definitions declared by candidates are also checked against that catalog.
  References never define new contracts. Optional providers may be absent; present
  providers must implement the exact referenced version and complete definition.
  """
  alias DomainContract.{Artifact, Info, Reference}

  @doc """
  Validates independent package declarations without requiring installed providers.

  Embedded snapshots supply their complete definitions for this structural check.
  Conflicting definitions of one identity/version are rejected, including conflicts
  between implemented and consumed references. This neither authenticates a snapshot's
  origin nor selects providers. Deployment activation still uses `check/2` with the
  immutable authoritative catalog and the complete selected candidate.

  Canonical maps are checked without loading or executing any provider code.
  """
  @spec validate([module() | map()]) :: :ok | {:error, [map()]}
  def validate(declarations) do
    invalid =
      for {source, index} <- Enum.with_index(declarations),
          Artifact.validate(source) != :ok,
          do: %{contract: index, reason: :invalid_artifact}

    if invalid == [] do
      declarations
      |> Enum.map(&Info.canonical/1)
      |> Enum.flat_map(fn contract ->
        definitions(contract) ++ (contract["implements"] || []) ++ (contract["consumes"] || [])
      end)
      |> conflicts()
      |> result()
    else
      {:error, invalid}
    end
  end

  @spec check([module() | map()], [module() | map()]) :: :ok | {:error, [map()]}
  def check(candidates, authorities \\ []) do
    with :ok <- validate(candidates ++ authorities), do: check_valid(candidates, authorities)
  end

  defp check_valid(candidates, authorities) do
    candidates = Enum.map(candidates, &Info.canonical/1)
    authorities = Enum.map(authorities, &Info.canonical/1)
    definitions = Enum.flat_map(authorities ++ candidates, &definitions/1)
    catalog = Enum.group_by(definitions, &key/1)

    providers =
      for candidate <- candidates, reference <- provided(candidate), do: {candidate, reference}

    duplicates =
      providers
      |> Enum.group_by(fn {_, reference} -> identity(reference) end)
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

    result(duplicates ++ errors ++ dependencies)
  end

  defp conflicts(references) do
    for {identity, values} <- Enum.group_by(references, &key/1),
        length(Enum.uniq_by(values, & &1["definition"])) > 1,
        do: %{interface: identity, reason: :conflicting_contract}
  end

  defp result([]), do: :ok
  defp result(errors), do: {:error, Enum.uniq(errors)}

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
  defp identity(reference), do: {reference["kind"], reference["name"]}

  defp verify_reference(reference, catalog) do
    # validate/1 has checked snapshot integrity and equality for this identity.
    # Presence in this separately supplied catalog establishes a known contract.
    if Map.has_key?(catalog, key(reference)), do: [], else: [:unknown_contract]
  end

  defp dependency(reference, providers) do
    case Enum.filter(providers, fn {_, provider} -> identity(provider) == identity(reference) end) do
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

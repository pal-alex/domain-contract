defmodule DomainContract.Upgrade do
  @moduledoc "Checks changed owners and affected edges against a previously admitted composition."
  alias DomainContract.Compatibility
  alias DomainContract.Info

  def prepare(current, candidate, live \\ []) do
    current = Enum.map(current, &declaration/1)
    candidate = Enum.map(candidate, &declaration/1)
    previous = Map.new(current, &{&1["module"], &1})
    selected = Map.new(candidate, &{&1["module"], &1})

    changed =
      MapSet.new(
        for name <- Enum.uniq(Map.keys(previous) ++ Map.keys(selected)),
            previous[name] != selected[name],
            do: name
      )

    affected =
      Enum.filter(candidate, fn owner ->
        MapSet.member?(changed, owner["module"]) or
          Enum.any?(
            (owner["consumes"] || []) ++ (owner["subscriptions"] || []),
            &MapSet.member?(changed, &1["module"])
          )
      end)

    # Unchanged providers have already passed admission. Strip their edges while
    # retaining their public surfaces to resolve the affected consumers directly.
    providers =
      Enum.reject(candidate, &(&1 in affected))
      |> Enum.map(fn owner ->
        owner |> Map.delete("digest") |> Map.put("consumes", []) |> Map.put("subscriptions", [])
      end)

    with true <- map_size(selected) == length(candidate),
         :ok <- Compatibility.validate(affected),
         :ok <- Compatibility.check_links(affected ++ providers),
         :ok <- live_requirements(affected_live(live, changed), selected) do
      {:ok,
       %{
         changed: changed,
         affected: Enum.map(affected, & &1["module"]),
         schemas: DomainContract.Schemas.index(candidate)
       }}
    else
      false -> {:error, [%{reason: :multiple_providers}]}
      error -> error
    end
  end

  defp affected_live(live, changed) do
    Enum.filter(live, fn consumer ->
      MapSet.member?(changed, consumer["module"]) or
        Enum.any?(
          (consumer["consumes"] || []) ++ (consumer["subscriptions"] || []),
          &MapSet.member?(changed, &1["module"])
        )
    end)
  end

  defp declaration(owner) do
    owner =
      if Map.has_key?(Info.canonical(owner), "schema"),
        do: DomainContract.Schemas.expand(owner),
        else: Info.canonical(owner)

    Map.delete(owner, "digest")
  end

  defp live_requirements(live, selected) do
    retained =
      Enum.map(live, fn owner ->
        if Map.has_key?(owner, "schema"),
          do: DomainContract.Schemas.expand(owner),
          else: Info.canonical(owner)
      end)

    errors = Enum.flat_map(retained, &scope_changes(&1, selected[&1["module"]]))

    # A live caller is an authorization declaration, never a second provider.
    retained =
      Enum.with_index(retained, fn owner, index ->
        owner
        |> Map.delete("digest")
        |> Map.put("schemas", DomainContract.Schemas.index([owner]))
        |> Map.put("module", "Elixir.DomainContract.Live#{index}")
      end)

    providers =
      Map.values(selected)
      |> Enum.map(fn owner ->
        owner |> Map.delete("digest") |> Map.put("consumes", []) |> Map.put("subscriptions", [])
      end)

    case Compatibility.check_links(providers ++ retained) do
      :ok when errors == [] -> :ok
      :ok -> {:error, errors}
      {:error, reasons} -> {:error, errors ++ reasons}
    end
  end

  defp scope_changes(_old, nil), do: []

  defp scope_changes(old, current) do
    missing =
      for ref <- current["consumes"] || [],
          not covered?(old, current, ref),
          do: %{
            consumer: old["module"],
            module: ref["module"],
            reason: :live_context_requires_migration
          }

    subscriptions = fn owner ->
      Enum.map(owner["subscriptions"] || [], &{&1["module"], &1["name"]}) |> MapSet.new()
    end

    if subscriptions.(old) == subscriptions.(current),
      do: missing,
      else: [%{consumer: old["module"], reason: :live_subscription_requires_migration} | missing]
  end

  defp covered?(old, current, required) do
    case Enum.find(old["consumes"] || [], &(&1["module"] == required["module"])) do
      nil ->
        false

      granted ->
        Compatibility.satisfies(
          DomainContract.Reference.definition(granted, DomainContract.Schemas.index([old])),
          DomainContract.Reference.definition(required, DomainContract.Schemas.index([current]))
        ) == :ok
    end
  end
end

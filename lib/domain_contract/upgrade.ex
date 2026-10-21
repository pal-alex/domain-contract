defmodule DomainContract.Upgrade do
  @moduledoc "Checks changed owners and affected edges against a previously admitted composition."
  alias DomainContract.Compatibility
  alias DomainContract.Info

  def prepare(current, candidate) do
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
         :ok <- Compatibility.check_links(affected ++ providers) do
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

  defp declaration(owner) do
    owner =
      if Map.has_key?(Info.canonical(owner), "schema"),
        do: DomainContract.Schemas.expand(owner),
        else: Info.canonical(owner)

    Map.delete(owner, "digest")
  end
end

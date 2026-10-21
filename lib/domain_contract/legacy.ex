defmodule DomainContract.Legacy do
  @moduledoc "One-time conversion of format 7 JSON exports. Executable packages must be rebuilt."
  alias DomainContract.Reference
  alias DomainContract.Schemas

  def convert(%{"format_version" => 7} = old) do
    if old["digest"] && old["digest"] != Reference.digest(old),
      do: raise(ArgumentError, "invalid format 7 digest")

    dependencies =
      Enum.map(old["consumes"] || [], fn ref ->
        owner = convert(ref["definition"])
        {Map.put(Schemas.reference(owner), "optional", ref["optional"]), owner}
      end)

    subscriptions =
      Enum.map(old["subscriptions"] || [], fn ref ->
        event = ref["definition"]

        owner = %{
          "format_version" => 8,
          "module" => ref["module"],
          "version" => 1,
          "kind" => "ui",
          "responsibility" => "Retained format 7 event requirement.",
          "description" => nil,
          "metadata" => %{},
          "entities" => event["entities"],
          "operations" => [],
          "commands" => [],
          "props" => [],
          "slots" => [],
          "notifications" => [
            %{"name" => ref["name"], "payload" => event["payload"], "description" => nil}
          ]
        }

        {Map.put(Schemas.reference(owner), "name", ref["name"]), owner}
      end)

    owner =
      old
      |> Map.delete("digest")
      |> Map.put("format_version", 8)
      |> Map.put("consumes", Enum.map(dependencies, &elem(&1, 0)))
      |> Map.put("subscriptions", Enum.map(subscriptions, &elem(&1, 0)))

    schemas =
      Schemas.index(Enum.map(dependencies ++ subscriptions, &elem(&1, 1)))
      |> Map.delete(Schemas.id(owner))

    owner = Map.put(owner, "schemas", schemas)

    if DomainContract.Artifact.validate(owner) != :ok,
      do: raise(ArgumentError, "invalid converted artifact")

    Map.put(owner, "digest", Reference.digest(owner))
  end

  def convert(%{"format_version" => 8} = owner), do: owner
end

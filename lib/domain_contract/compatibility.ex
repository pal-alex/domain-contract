defmodule DomainContract.Compatibility do
  @moduledoc "Checks declared consumer requirements against exported provider contracts."

  @spec check([map()]) :: :ok | {:error, [map()]}
  def check(contracts) do
    providers =
      for contract <- contracts, interface <- contract["interfaces"], do: {contract, interface}

    duplicates =
      providers
      |> Enum.group_by(fn {_, interface} -> identity(interface) end)
      |> Enum.flat_map(fn
        {_, [_]} -> []
        {key, _} -> [%{interface: key, reason: :multiple_providers}]
      end)

    errors =
      for consumer <- contracts,
          required <- consumer["consumes"] || [],
          error <- requirement(consumer, required, providers),
          do: error

    case duplicates ++ errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp identity(interface), do: {interface["kind"], interface["name"]}

  defp requirement(consumer, required, providers) do
    case Enum.filter(providers, fn {_, provided} -> identity(provided) == identity(required) end) do
      [{provider, provided}] ->
        if provided["version"] >= required["version"] do
          for expected <- required["operations"],
              reason <- operation(consumer, expected, provider, provided),
              do: %{
                consumer: consumer["domain"],
                interface: identity(required),
                operation: expected["name"],
                reason: reason
              }
        else
          [
            %{
              consumer: consumer["domain"],
              interface: identity(required),
              reason: :version_too_old
            }
          ]
        end

      [] ->
        [
          %{
            consumer: consumer["domain"],
            interface: identity(required),
            reason: :missing_provider
          }
        ]

      _ ->
        []
    end
  end

  defp operation(consumer, expected, provider, interface) do
    case Enum.find(interface["operations"], &(&1["name"] == expected["name"])) do
      nil ->
        [:missing_operation]

      actual ->
        input =
          subset?(
            ["entity", expected["input"]],
            consumer,
            ["entity", actual["input"]],
            provider,
            :closed,
            MapSet.new()
          )

        output =
          (expected["optional_output"] or not actual["optional_output"]) and
            subset?(
              ["entity", actual["output"]],
              provider,
              ["entity", expected["output"]],
              consumer,
              :projection,
              MapSet.new()
            )

        if(input, do: [], else: [:incompatible_input]) ++
          if(output, do: [], else: [:incompatible_output])
    end
  end

  defp subset?(_, _, "opaque", _, _, _), do: true
  defp subset?("opaque", _, _, _, _, _), do: false
  defp subset?(type, _, type, _, _, _) when is_binary(type), do: true
  defp subset?("integer", _, "float", _, _, _), do: true
  defp subset?("datetime", _, "string", _, _, _), do: true

  defp subset?(type, _, "json_scalar", _, _, _)
       when type in ~w(string integer float boolean datetime),
       do: true

  defp subset?(["enum", _], _, type, _, _, _) when type in ~w(string json_scalar), do: true

  defp subset?(["enum", sent], _, ["enum", accepted], _, _, _),
    do: Enum.all?(sent, &(&1 in accepted))

  defp subset?(["entity", _], _, "map", _, _, _), do: true
  defp subset?(["dictionary", _], _, "map", _, _, _), do: true
  defp subset?(["variant", _], _, "map", _, _, _), do: true

  defp subset?(["entity", left], sender, ["entity", right], receiver, mode, seen) do
    key = {sender, left, receiver, right, mode}

    if MapSet.member?(seen, key) do
      true
    else
      fields?(
        entity(sender, left),
        sender,
        entity(receiver, right),
        receiver,
        mode,
        MapSet.put(seen, key)
      )
    end
  end

  defp subset?([container, left], sender, [container, right], receiver, mode, seen)
       when container in ~w(list dictionary) do
    subset?(left, sender, right, receiver, mode, seen)
  end

  defp subset?(["variant", left], sender, ["variant", right], receiver, mode, seen) do
    Enum.all?(left, fn {tag, type} ->
      Map.has_key?(right, tag) and subset?(type, sender, right[tag], receiver, mode, seen)
    end)
  end

  defp subset?(_, _, _, _, _, _), do: false

  defp entity(contract, name), do: Enum.find(contract["entities"], &(&1["name"] == name))

  defp fields?(sent, sender, accepted, receiver, mode, seen) do
    sent = Map.new(sent["fields"], &{&1["name"], &1})
    accepted = Map.new(accepted["fields"], &{&1["name"], &1})

    known = mode == :projection or Enum.all?(Map.keys(sent), &Map.has_key?(accepted, &1))

    known and
      Enum.all?(accepted, fn {name, field} ->
        case sent[name] do
          nil ->
            field["optional"]

          value ->
            (field["optional"] or not value["optional"]) and
              subset?(value["type"], sender, field["type"], receiver, mode, seen)
        end
      end)
  end
end

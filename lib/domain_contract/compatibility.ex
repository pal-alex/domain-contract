defmodule DomainContract.Compatibility do
  @moduledoc "Directional structural compatibility. Versions and digests identify history, not compatibility."
  alias DomainContract.Artifact
  alias DomainContract.Info

  def validate(contracts) do
    errors =
      for {contract, index} <- Enum.with_index(contracts),
          Artifact.validate(contract) != :ok,
          do: %{contract: index, reason: :invalid_artifact}

    result(errors)
  end

  def check(candidates, authorities \\ []) do
    with :ok <- validate(candidates ++ authorities) do
      candidates = Enum.map(candidates, &Info.canonical/1)
      providers = Enum.group_by(candidates, & &1["module"])

      duplicates =
        for {module, [_ | rest]} <- providers,
            rest != [],
            do: %{module: module, reason: :multiple_providers}

      errors =
        for consumer <- candidates,
            ref <- consumer["consumes"],
            reason <- dependency(ref, providers),
            do: %{consumer: consumer["module"], module: ref["module"], reason: reason}

      subscriptions =
        for consumer <- candidates,
            ref <- consumer["subscriptions"],
            reason <- subscription(ref, providers),
            do: %{consumer: consumer["module"], module: ref["module"], reason: reason}

      result(duplicates ++ errors ++ subscriptions)
    end
  end

  def provided(source) do
    owner = Info.canonical(source)

    if owner["operations"] == [],
      do: [],
      else: [
        %{"module" => owner["module"], "definition" => DomainContract.Reference.snapshot(owner)}
      ]
  end

  def satisfies(provider, requirements) do
    provider = Info.canonical(provider)
    requirements = Info.canonical(requirements)

    if provider["module"] != requirements["module"] do
      {:error, [%{reason: :different_module}]}
    else
      errors =
        operations(provider, requirements, "operations", [:input, :output]) ++
          operations(provider, requirements, "commands", [:payload]) ++
          operations(provider, requirements, "notifications", [:notification]) ++
          props(provider, requirements)

      result(errors)
    end
  end

  defp dependency(ref, providers) do
    case Map.get(providers, ref["module"], []) do
      [] ->
        if ref["optional"], do: [], else: [:missing_provider]

      [provider] ->
        case satisfies(provider, ref["definition"]) do
          :ok -> []
          {:error, errors} -> errors
        end

      _ ->
        []
    end
  end

  defp subscription(ref, providers) do
    case Map.get(providers, ref["module"], []) do
      [provider] ->
        case Enum.find(provider["notifications"], &(&1["name"] == ref["name"])) do
          nil ->
            [:missing_notification]

          event ->
            old = ref["definition"]

            if subset?(event["payload"], old["payload"], provider["entities"], old["entities"]),
              do: [],
              else: [:incompatible_notification]
        end

      [] ->
        [:missing_provider]

      _ ->
        []
    end
  end

  defp operations(provider, required, key, directions) do
    for old <- required[key],
        direction <- directions,
        error <- compare_operation(provider, required, old, key, direction),
        do: error
  end

  defp compare_operation(provider, required, old, key, direction) do
    case Enum.find(provider[key], &(&1["name"] == old["name"])) do
      nil ->
        [%{surface: key, name: old["name"], reason: :removed}]

      new ->
        {left, right, left_entities, right_entities} =
          if direction in [:input, :payload] do
            {root(old, direction), root(new, direction), required["entities"],
             provider["entities"]}
          else
            {root(new, direction), root(old, direction), provider["entities"],
             required["entities"]}
          end

        if subset?(left, right, left_entities, right_entities),
          do: [],
          else: [
            %{surface: key, name: old["name"], direction: direction, reason: :incompatible_type}
          ]
    end
  end

  defp props(provider, required) do
    # Props flow from the old caller into the replacement component.
    old = fields(required["props"])
    new = fields(provider["props"])

    if object_subset?(
         old,
         new,
         required["entities"],
         provider["entities"],
         false,
         false,
         MapSet.new()
       ),
       do: [],
       else: [%{surface: "props", reason: :incompatible_type}]
  end

  defp fields(props),
    do:
      Enum.map(
        props,
        &%{"name" => &1["name"], "type" => &1["type"], "optional" => not &1["required"]}
      )

  defp root(op, :notification), do: op["payload"]
  defp root(op, :payload), do: op["payload"]

  defp root(op, direction) do
    side = to_string(direction)
    type = op[side <> "_type"] || ["entity", op[side]]
    if direction == :output and op["optional_output"], do: ["nullable", type], else: type
  end

  @doc "True when every value of the first type is accepted by the second type."
  def subset?(left, right, left_entities \\ [], right_entities \\ []),
    do:
      subset(
        left,
        right,
        Map.new(left_entities, &{&1["name"], &1}),
        Map.new(right_entities, &{&1["name"], &1}),
        MapSet.new()
      )

  defp subset(_, top, _, _, _) when top in ["opaque", "any"], do: true

  defp subset(["nullable", t], right, le, re, seen),
    do: subset(["union", ["null", t]], right, le, re, seen)

  defp subset(left, ["nullable", t], le, re, seen),
    do: subset(left, ["union", ["null", t]], le, re, seen)

  defp subset(["union", types], right, le, re, seen),
    do: Enum.all?(types, &subset(&1, right, le, re, seen))

  defp subset(left, ["union", types], le, re, seen),
    do: Enum.any?(types, &subset(left, &1, le, re, seen))

  defp subset(["enum", left], ["enum", right], _, _, _),
    do: Enum.all?(left, fn value -> Enum.any?(right, &(&1 === value)) end)

  defp subset(["enum", values], right, _, _, _),
    do: Enum.all?(values, &enum_accepted?(&1, right))

  defp subset("integer", "float", _, _, _), do: true

  defp subset(left, "json_scalar", _, _, _) when left in ~w(string integer float boolean null),
    do: true

  defp subset([container, l], [container, r], le, re, seen) when container in ~w(list dictionary),
    do: subset(l, r, le, re, seen)

  defp subset(["variant", l], ["variant", r], le, re, seen),
    do: Enum.all?(l, fn {key, t} -> Map.has_key?(r, key) and subset(t, r[key], le, re, seen) end)

  defp subset([lk, ln], [rk, rn], le, re, seen)
       when lk in ~w(entity open_entity) and rk in ~w(entity open_entity) do
    key = {lk, ln, rk, rn}

    if MapSet.member?(seen, key),
      do: true,
      else:
        object_subset?(
          le[ln]["fields"],
          re[rn]["fields"],
          le,
          re,
          lk == "open_entity",
          rk == "open_entity",
          MapSet.put(seen, key)
        )
  end

  defp subset(left, right, le, re, seen) when is_map(left) and is_map(right) do
    fields = fn map ->
      Enum.map(map, fn {k, v} -> %{"name" => k, "type" => v, "optional" => false} end)
    end

    object_subset?(fields.(left), fields.(right), le, re, false, false, seen)
  end

  defp subset(left, right, _, _, _) when is_binary(left) and is_binary(right), do: left == right
  defp subset(_, _, _, _, _), do: false

  defp enum_accepted?(["atom", _], "atom"), do: true
  defp enum_accepted?(["atom", _], _), do: false
  defp enum_accepted?(value, type), do: DomainContract.Runtime.validate_type(type, value) == :ok

  defp object_subset?(left, right, le, re, lo, ro, seen) do
    le = if is_list(le), do: Map.new(le, &{&1["name"], &1}), else: le
    re = if is_list(re), do: Map.new(re, &{&1["name"], &1}), else: re
    l = Map.new(left, &{&1["name"], &1})
    r = Map.new(right, &{&1["name"], &1})

    (not lo or ro) and (ro or Enum.all?(Map.keys(l), &Map.has_key?(r, &1))) and
      Enum.all?(right, fn field ->
        case l[field["name"]] do
          nil ->
            field["optional"] and not lo

          old ->
            (field["optional"] or not old["optional"]) and
              subset(old["type"], field["type"], le, re, seen)
        end
      end)
  end

  defp result([]), do: :ok
  defp result(errors), do: {:error, Enum.uniq(errors)}
end

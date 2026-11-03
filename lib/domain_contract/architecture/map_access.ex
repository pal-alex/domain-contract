defmodule DomainContract.Architecture.MapAccess do
  @moduledoc false

  # no_parens alone is not proof: `module.field` also dispatches a function.
  # Only a matching map/struct pattern, an is_map guard, or a local map binding
  # proves this access is data. Compiler variable versions prevent rebinding
  # and branch-local facts from escaping their scope.
  def annotate(body, args, guards) do
    annotate(body, MapSet.union(patterns(args), guards(guards)))
  end

  defp annotate({:__block__, meta, nodes}, known) do
    {nodes, _} =
      Enum.map_reduce(nodes, known, fn node, known ->
        next = MapSet.union(known, patterns(node))
        {annotate(node, next), next}
      end)

    {:__block__, meta, nodes}
  end

  defp annotate({:->, meta, [args, body]}, known) do
    scoped = MapSet.union(known, patterns(args))
    scoped = MapSet.union(scoped, pattern_guards(args))
    {:->, meta, [annotate(args, known), annotate(body, scoped)]}
  end

  defp annotate({{:., dot, [receiver, name]}, meta, []}, known) do
    proven =
      meta[:no_parens] == true and
        (map?(receiver) or MapSet.member?(known, variable(receiver)))

    {{:., dot, [annotate(receiver, known), name]},
     Keyword.put(meta, :domain_contract_map_access, proven), []}
  end

  defp annotate(tuple, known) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&annotate(&1, known)) |> List.to_tuple()

  defp annotate(list, known) when is_list(list), do: Enum.map(list, &annotate(&1, known))
  defp annotate(value, _), do: value

  defp patterns({:=, _, [left, right]}) do
    values = if map?(left), do: [variable(right)], else: []
    values = if map?(right), do: [variable(left) | values], else: values
    MapSet.union(MapSet.new(Enum.reject(values, &is_nil/1)), patterns([left, right]))
  end

  # Facts in a nested branch are scoped by annotate/2, not by its enclosing block.
  defp patterns({:->, _, _}), do: MapSet.new()
  defp patterns(tuple) when is_tuple(tuple), do: patterns(Tuple.to_list(tuple))

  defp patterns(list) when is_list(list),
    do: Enum.reduce(list, MapSet.new(), &MapSet.union(patterns(&1), &2))

  defp patterns(_), do: MapSet.new()

  defp pattern_guards([{:when, _, args}]), do: guard(List.last(args))
  defp pattern_guards(_), do: MapSet.new()

  defp guards([]), do: MapSet.new()

  defp guards([first | rest]),
    do: Enum.reduce(rest, guard(first), &MapSet.intersection(guard(&1), &2))

  defp guard({{:., _, [:erlang, :is_map]}, _, [value]}) do
    case variable(value) do
      nil -> MapSet.new()
      key -> MapSet.new([key])
    end
  end

  defp guard({{:., _, [:erlang, :andalso]}, _, [left, right]}),
    do: MapSet.union(guard(left), guard(right))

  defp guard({{:., _, [:erlang, :orelse]}, _, [left, right]}),
    do: MapSet.intersection(guard(left), guard(right))

  defp guard(_), do: MapSet.new()

  defp map?({:%{}, _, _}), do: true
  defp map?({:%, _, _}), do: true
  defp map?(_), do: false

  defp variable({name, meta, context}) when is_atom(name) and is_atom(context) do
    case Keyword.fetch(meta, :version) do
      {:ok, version} -> {name, version, context}
      :error -> nil
    end
  end

  defp variable(_), do: nil
end

defmodule DomainContract.Architecture.MapAccess do
  @moduledoc false

  # Facts describe values, keyed by compiler variable version and context. A map
  # fact can also describe fields that are themselves maps. no_parens, variable
  # names, generated metadata and the existence of a render callback prove nothing.
  def annotate(body, args, guards, returns \\ %{}) do
    known = merge(bind_many(args, %{}, returns), guards(guards))
    walk(body, known, returns)
  end

  # A local call may use a result shape only when every compiled clause returns
  # a map literal. Do not evaluate code, trust specs or infer permissions from it.
  def literal_returns(definitions) do
    for {signature, kind, _, clauses} <- definitions,
        kind in [:def, :defp],
        clauses != [],
        shapes = Enum.map(clauses, fn {_, _, _, body} -> literal_return(body) end),
        Enum.all?(shapes, &match?({:map, _}, &1)),
        into: %{},
        do: {signature, Enum.reduce(shapes, &common/2)}
  end

  defp literal_return({:__block__, _, nodes}), do: literal_return(List.last(nodes))

  defp literal_return({kind, _, args} = node) when kind in [:%{}, :%] and is_list(args),
    do: shape(node, %{}, %{})

  defp literal_return(_), do: nil

  defp walk({:__block__, meta, nodes}, known, returns) do
    {nodes, _} =
      Enum.map_reduce(nodes, known, fn node, known ->
        {walk(node, known, returns), facts(node, known, returns)}
      end)

    {:__block__, meta, nodes}
  end

  defp walk({:case, meta, [subject, [do: clauses]]}, known, returns) do
    clauses =
      Enum.map(clauses, fn {:->, meta, [[pattern], body]} ->
        scoped = bind(pattern, shape(subject, known, returns), known, returns)
        scoped = merge(scoped, pattern_guards([pattern]))
        scoped = constrain(subject, shape(pattern, scoped, returns), scoped)
        {:->, meta, [[walk(pattern, known, returns)], walk(body, scoped, returns)]}
      end)

    {:case, meta, [walk(subject, known, returns), [do: clauses]]}
  end

  defp walk({:->, meta, [args, body]}, known, returns) do
    scoped = merge(bind_many(args, known, returns), pattern_guards(args))
    {:->, meta, [walk(args, known, returns), walk(body, scoped, returns)]}
  end

  defp walk({kind, meta, args}, known, returns) when kind in [:with, :for] and is_list(args) do
    {qualifiers, [options]} = Enum.split(args, -1)

    {qualifiers, scoped} =
      Enum.map_reduce(qualifiers, known, fn
        {:<-, meta, [pattern, expression]}, known ->
          # A comprehension matches each element, not the enumerable itself.
          value = if kind == :with, do: shape(expression, known, returns)
          scoped = bind(pattern, value, known, returns)
          scoped = merge(scoped, pattern_guards([pattern]))

          {{:<-, meta, [walk(pattern, known, returns), walk(expression, known, returns)]}, scoped}

        expression, known ->
          {walk(expression, known, returns), facts(expression, known, returns)}
      end)

    options =
      Enum.map(options, fn
        {:do, body} -> {:do, walk(body, scoped, returns)}
        {key, body} -> {key, walk(body, known, returns)}
      end)

    {kind, meta, qualifiers ++ [options]}
  end

  defp walk({{:., dot, [receiver, name]}, meta, []}, known, returns) do
    proven = meta[:no_parens] == true and match?({:map, _}, shape(receiver, known, returns))

    {{:., dot, [walk(receiver, known, returns), name]},
     Keyword.put(meta, :domain_contract_map_access, proven), []}
  end

  defp walk(tuple, known, returns) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&walk(&1, known, returns)) |> List.to_tuple()

  defp walk(list, known, returns) when is_list(list),
    do: Enum.map(list, &walk(&1, known, returns))

  defp walk(value, _, _), do: value

  # Only facts from expressions that have already completed may reach the next
  # expression. In particular, never harvest matches from branches or closures.
  defp facts({:__block__, _, nodes}, known, returns),
    do: Enum.reduce(nodes, known, &facts(&1, &2, returns))

  defp facts({:=, _, [left, right]}, known, returns) do
    known = facts(right, known, returns)
    known = bind(left, shape(right, known, returns), known, returns)
    constrain(right, shape(left, known, returns), known)
  end

  defp facts(_, known, _), do: known

  defp bind_many(patterns, known, returns),
    do: Enum.reduce(patterns, known, &bind(&1, nil, &2, returns))

  defp bind({:when, _, args}, value, known, returns) do
    Enum.reduce(Enum.drop(args, -1), known, &bind(&1, value, &2, returns))
  end

  defp bind({:=, _, [left, right]}, value, known, returns) do
    value = combine(value, combine(shape(left, known, returns), shape(right, known, returns)))
    known = bind(left, value, known, returns)
    bind(right, value, known, returns)
  end

  defp bind({:%, _, [_, fields]}, value, known, returns), do: bind(fields, value, known, returns)

  defp bind({:%{}, _, fields}, value, known, returns) do
    Enum.reduce(fields, known, fn
      {key, pattern}, known -> bind(pattern, field(value, key), known, returns)
      _, known -> known
    end)
  end

  defp bind({:{}, _, patterns}, value, known, returns),
    do: bind_tuple(patterns, value, known, returns)

  defp bind({left, right}, value, known, returns),
    do: bind_tuple([left, right], value, known, returns)

  defp bind(list, _value, known, returns) when is_list(list), do: bind_many(list, known, returns)
  defp bind(pattern, value, known, _), do: constrain(pattern, value, known)

  defp bind_tuple(patterns, value, known, returns) do
    values =
      case value do
        {:tuple, values} when length(values) == length(patterns) -> values
        _ -> List.duplicate(nil, length(patterns))
      end

    Enum.zip(patterns, values)
    |> Enum.reduce(known, fn {pattern, value}, known -> bind(pattern, value, known, returns) end)
  end

  defp constrain({:=, _, [left, right]}, value, known),
    do: constrain(right, value, constrain(left, value, known))

  defp constrain(node, value, known) do
    case {variable(node), value} do
      {nil, _} -> known
      {_, nil} -> known
      {key, value} -> Map.update(known, key, value, &combine(&1, value))
    end
  end

  defp shape({:when, _, args}, known, returns), do: shape(List.first(args), known, returns)

  defp shape({:=, _, [left, right]}, known, returns),
    do: combine(shape(left, known, returns), shape(right, known, returns))

  defp shape({:%, _, [_, fields]}, known, returns), do: shape(fields, known, returns)

  # Updates always produce a map, but may replace a known nested field.
  defp shape({:%{}, _, [{:|, _, _}]}, _, _), do: {:map, %{}}

  defp shape({:%{}, _, fields}, known, returns) do
    fields =
      if Enum.all?(fields, fn {key, _} -> literal_key?(key) end),
        do: Map.new(fields, fn {key, value} -> {key, shape(value, known, returns)} end),
        else: %{}

    {:map, fields}
  end

  defp shape({:{}, _, values}, known, returns),
    do: {:tuple, Enum.map(values, &shape(&1, known, returns))}

  defp shape({left, right}, known, returns),
    do: {:tuple, Enum.map([left, right], &shape(&1, known, returns))}

  defp shape({{:., _, [receiver, key]}, meta, []}, known, returns) do
    if meta[:no_parens] == true, do: field(shape(receiver, known, returns), key)
  end

  # TagEngine may return its input unchanged. It preserves a map proof; it does
  # not establish one for an untyped assigns variable. __changed__ may be replaced.
  defp shape(
         {{:., _, [Phoenix.LiveView.TagEngine, :__assigns__]}, _, [input, _, _]},
         known,
         returns
       ) do
    case shape(input, known, returns) do
      {:map, fields} -> {:map, Map.delete(fields, :__changed__)}
      _ -> nil
    end
  end

  defp shape({name, _, args}, _, returns) when is_atom(name) and is_list(args),
    do: Map.get(returns, {name, length(args)})

  defp shape(node, known, _), do: Map.get(known, variable(node))

  defp field({:map, fields}, key), do: Map.get(fields, key)
  defp field(_, _), do: nil
  defp literal_key?(key), do: is_atom(key) or is_binary(key) or is_number(key)

  defp pattern_guards([{:when, _, args}]), do: guard(List.last(args))
  defp pattern_guards(_), do: %{}
  defp guards([]), do: %{}
  defp guards([first | rest]), do: Enum.reduce(rest, guard(first), &intersect(guard(&1), &2))

  defp guard({{:., _, [:erlang, :is_map]}, _, [value]}),
    do: constrain(value, {:map, %{}}, %{})

  defp guard({{:., _, [:erlang, :andalso]}, _, [left, right]}),
    do: merge(guard(left), guard(right))

  defp guard({{:., _, [:erlang, :orelse]}, _, [left, right]}),
    do: intersect(guard(left), guard(right))

  defp guard(_), do: %{}

  defp merge(left, right), do: Map.merge(left, right, fn _, a, b -> combine(a, b) end)

  defp intersect(left, right),
    do:
      Map.new(
        for {key, value} <- left, Map.has_key?(right, key), do: {key, common(value, right[key])}
      )

  # combine joins simultaneous constraints; common retains facts true on every
  # alternative (OR guards and function clauses).
  defp combine(nil, right), do: right
  defp combine(left, nil), do: left
  defp combine({:map, left}, {:map, right}), do: {:map, merge(left, right)}

  defp combine({:tuple, left}, {:tuple, right}) when length(left) == length(right),
    do: {:tuple, Enum.zip_with(left, right, &combine/2)}

  defp combine(_, _), do: nil

  defp common({:map, left}, {:map, right}), do: {:map, intersect(left, right)}

  defp common({:tuple, left}, {:tuple, right}) when length(left) == length(right),
    do: {:tuple, Enum.zip_with(left, right, &common/2)}

  defp common(_, _), do: nil

  defp variable({name, meta, context}) when is_atom(name) and is_atom(context) do
    case Keyword.fetch(meta, :version) do
      {:ok, version} -> {name, version, context}
      :error -> nil
    end
  end

  defp variable(_), do: nil
end

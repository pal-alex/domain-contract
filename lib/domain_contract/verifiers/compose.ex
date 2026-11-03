defmodule DomainContract.Verifiers.Compose do
  @moduledoc false
  alias DomainContract
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Extension
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  def compose(dsl, owner) do
    {groups, dsl} = Enum.map_reduce(owner.entities, dsl, &entity_group/2)
    {operations, dsl} = Enum.map_reduce(owner.operations, dsl, &operation_group/2)

    {operations, local} =
      operations
      |> List.flatten()
      |> Enum.map_reduce([], fn operation, entities ->
        {operation, local} = local_contracts(dsl, operation)
        {operation, entities ++ local}
      end)

    groups = groups ++ Enum.map(local, &{[&1], [name(&1)], &1})

    candidates =
      Enum.flat_map(groups, fn {entities, _, source} -> Enum.map(entities, &{&1, source}) end)

    roots = Enum.flat_map(groups, fn {_, roots, _} -> roots end)
    entities = select(dsl, candidates, roots)
    {%{owner | operations: operations, entities: entities}, dsl}
  end

  defp entity_group(%DomainContract.DeclarationReference{} = reference, dsl) do
    if is_nil(reference.only) or fragment?(reference.module) do
      entities = declarations(dsl, reference)
      roots = roots(dsl, entities, reference)
      {{entities, roots, reference}, track_fragment(dsl, reference.module)}
    else
      # Keep canonical maps intact: no atom conversion or schema round-trip.
      entities = DomainContract.Reference.resolve_metadata(reference.module)["entities"]
      roots = roots(dsl, entities, reference)
      selected = select(dsl, Enum.map(entities, &{&1, reference}), roots)
      {{selected, roots, reference}, dsl}
    end
  end

  defp entity_group(entity, dsl), do: {{[entity], [name(entity)], entity}, dsl}

  defp operation_group(%DomainContract.DeclarationReference{} = reference, dsl),
    do: {declarations(dsl, reference), track_fragment(dsl, reference.module)}

  defp operation_group(operation, dsl), do: {[operation], dsl}

  defp track_fragment(dsl, module) do
    Transformer.eval(dsl, [], quote(do: unquote(module).spark_dsl_config()))
  end

  # Never ensure_compiled an unclassified module: that can run a provider's
  # on_load callback. Fragments compiled concurrently must be explicitly required.
  defp fragment?(module) do
    attributes =
      if :code.is_loaded(module) != false do
        :erlang.get_module_info(module, :attributes)
      else
        with path when is_list(path) <- :code.which(module),
             {:ok, {^module, chunks}} <- :beam_lib.chunks(path, [:attributes]) do
          chunks[:attributes]
        else
          _ -> []
        end
      end

    attributes[:spark_fragment_of] == [DomainContract]
  end

  defp roots(dsl, entities, reference) do
    names = Enum.map(entities, &name/1)

    roots =
      if is_nil(reference.only),
        do: names,
        else: Enum.uniq(Enum.map(reference.only, &to_string/1))

    Enum.each(roots -- names, fn root ->
      fail(dsl, reference, "unknown entity #{inspect(root)} in #{inspect(reference.module)}")
    end)

    roots
  end

  defp select(dsl, candidates, roots) do
    index = Enum.group_by(candidates, fn {entity, _} -> name(entity) end)
    selected = visit(dsl, roots, index, MapSet.new())

    candidates
    |> Enum.filter(fn {entity, _} -> MapSet.member?(selected, name(entity)) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp visit(_dsl, [], _index, seen), do: seen

  defp visit(dsl, [name | rest], index, seen) do
    if MapSet.member?(seen, name) do
      visit(dsl, rest, index, seen)
    else
      case Map.get(index, name, []) do
        [{entity, source}] ->
          dependencies =
            entity
            |> DomainContract.Info.normalize()
            |> Map.fetch!("fields")
            |> Enum.flat_map(&dependencies(&1["type"]))

          Enum.each(dependencies, fn dependency ->
            unless Map.has_key?(index, dependency),
              do:
                fail(
                  dsl,
                  source,
                  "entity #{inspect(name)} references missing entity #{inspect(dependency)}"
                )
          end)

          visit(dsl, dependencies ++ rest, index, MapSet.put(seen, name))

        [{_, source} | _] ->
          fail(dsl, source, "entity name collision for #{inspect(name)} in composed contract")
      end
    end
  end

  defp name(%{name: name}), do: to_string(name)
  defp name(%{"name" => name}), do: name

  defp dependencies([kind, name]) when kind in ["entity", "open_entity"], do: [name]

  defp dependencies([kind, type]) when kind in ["list", "dictionary", "nullable"],
    do: dependencies(type)

  defp dependencies(["union", types]), do: Enum.flat_map(types, &dependencies/1)
  defp dependencies(["variant", choices]), do: dependencies(choices)

  defp dependencies(fields) when is_map(fields),
    do: Enum.flat_map(fields, fn {_, type} -> dependencies(type) end)

  defp dependencies(_), do: []

  defp declarations(dsl, reference) do
    module = reference.module

    with {:module, _} <- Code.ensure_compiled(module),
         true <- function_exported?(module, :opts, 0),
         true <- module.opts()[:of] == DomainContract do
      config = module.spark_dsl_config()

      if Extension.get_opt(config, [:contract], :version) do
        fail(dsl, reference, "a DomainContract fragment must contain declarations, not a domain")
      end

      declarations = Extension.get_entities(config, [:declarations])

      expected =
        if reference.kind == :entities, do: DomainContract.Entity, else: DomainContract.Operation

      if declarations == [] or Enum.any?(declarations, &(&1.__struct__ != expected)) do
        fail(dsl, reference, "#{inspect(module)} must declare only #{reference.kind}")
      end

      declarations
    else
      _ -> fail(dsl, reference, "#{inspect(module)} must be a DomainContract fragment")
    end
  end

  defp local_contracts(dsl, operation) do
    Enum.reduce([:input, :output], {operation, []}, fn property, {operation, entities} ->
      key = if property == :input, do: :inputs, else: :outputs
      local = Map.fetch!(operation, key)
      reference = Map.fetch!(operation, property)
      type = Map.fetch!(operation, if(property == :input, do: :input_type, else: :output_type))

      case {reference, local, type} do
        {nil, [], type} when not is_nil(type) ->
          {operation, entities}

        {nil, [entity], nil} ->
          {operation |> Map.put(property, entity.name) |> Map.put(key, []), entities ++ [entity]}

        {name, [], nil} when is_atom(name) and not is_nil(name) ->
          {operation, entities}

        _ ->
          fail(
            dsl,
            List.last(local) || operation,
            "operation #{inspect(operation.name)} requires exactly one #{property} reference, local entity or #{property}_type"
          )
      end
    end)
  end

  defp fail(dsl, entity, message) do
    raise DslError,
      module: Transformer.get_persisted(dsl, :module),
      path: [:domain, :composition],
      message: message,
      location: Entity.anno(entity)
  end
end

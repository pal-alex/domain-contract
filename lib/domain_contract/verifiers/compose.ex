defmodule DomainContract.Verifiers.Compose do
  @moduledoc false
  alias DomainContract
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Extension
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  def compose(dsl, owner) do
    entities = expand(dsl, owner.entities)

    {operations, local} =
      owner.operations
      |> then(&expand(dsl, &1))
      |> Enum.map_reduce([], fn operation, entities ->
        {operation, local} = local_contracts(dsl, operation)
        {operation, entities ++ local}
      end)

    dsl = Enum.reduce(owner.entities ++ owner.operations, dsl, &track_fragment/2)
    {%{owner | operations: operations, entities: entities ++ local}, dsl}
  end

  defp track_fragment(%DomainContract.DeclarationReference{module: module}, dsl) do
    Transformer.eval(dsl, [], quote(do: unquote(module).spark_dsl_config()))
  end

  defp track_fragment(_, dsl), do: dsl

  defp expand(dsl, declarations) do
    Enum.flat_map(declarations, fn
      %DomainContract.DeclarationReference{} = reference -> declarations(dsl, reference)
      declaration -> [declaration]
    end)
  end

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

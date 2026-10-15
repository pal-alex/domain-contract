defmodule DomainContract.Verifiers.Compose do
  @moduledoc false
  alias DomainContract
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Extension
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  def transform(dsl) do
    domains = Transformer.get_entities(dsl, [:contract])
    declarations = Transformer.get_entities(dsl, [:declarations])

    if declarations != [] do
      fail(dsl, hd(declarations), "declarations belong in a DomainContract fragment")
    end

    # Exactly-one-domain diagnostics belong to Validate, including their location.
    case domains do
      [domain] -> compose(dsl, domain)
      _ -> {:ok, dsl}
    end
  rescue
    error in DslError -> {:error, error}
  end

  defp compose(dsl, domain) do
    entities = expand(dsl, domain.entities)

    {interfaces, local_entities} = compose_interfaces(dsl, domain.interfaces)
    {consumes, consumed_entities} = compose_interfaces(dsl, domain.consumes)

    references =
      domain.entities ++
        Enum.flat_map(domain.interfaces ++ domain.consumes, & &1.operations)

    dsl = Enum.reduce(references, dsl, &track_fragment/2)

    domain = %{
      domain
      | interfaces: interfaces,
        consumes: consumes,
        entities: entities ++ local_entities ++ consumed_entities
    }

    {:ok, Transformer.replace_entity(dsl, [:contract], domain, fn _ -> true end)}
  end

  defp compose_interfaces(dsl, interfaces) do
    Enum.map_reduce(interfaces, [], fn interface, entities ->
      {operations, local} =
        interface.operations
        |> then(&expand(dsl, &1))
        |> Enum.map_reduce([], fn operation, entities ->
          {operation, local} = local_contracts(dsl, operation)
          {operation, entities ++ local}
        end)

      {%{interface | operations: operations}, entities ++ local}
    end)
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

      if Extension.get_entities(config, [:contract]) != [] do
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

      case {reference, local} do
        {nil, [entity]} ->
          {operation |> Map.put(property, entity.name) |> Map.put(key, []), entities ++ [entity]}

        {name, []} when is_atom(name) and not is_nil(name) ->
          {operation, entities}

        _ ->
          fail(
            dsl,
            List.last(local) || operation,
            "operation #{inspect(operation.name)} requires exactly one #{property} reference or local entity"
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

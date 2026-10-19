defmodule DomainContract.Verifiers.References do
  @moduledoc false
  alias DomainContract.Reference
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  def transform(dsl) do
    case Transformer.get_entities(dsl, [:contract]) do
      [domain] ->
        {consumes, dsl} = Enum.map_reduce(domain.consumes, dsl, &resolve/2)
        {implements, dsl} = Enum.map_reduce(domain.implements, dsl, &resolve/2)
        domain = %{domain | consumes: consumes, implements: implements}
        {:ok, Transformer.replace_entity(dsl, [:contract], domain, fn _ -> true end)}

      _ ->
        {:ok, dsl}
    end
  rescue
    error in DslError -> {:error, error}
  end

  defp resolve(reference, dsl) do
    definition =
      Reference.resolve(reference.contract, reference.name, reference.version, reference.kind)

    dsl =
      cond do
        is_binary(reference.contract) ->
          Transformer.eval(
            dsl,
            [],
            quote do
              @external_resource unquote(Path.expand(reference.contract))
            end
          )

        is_atom(reference.contract) ->
          Transformer.eval(
            dsl,
            [],
            quote do
              unquote(reference.contract).entities([:contract])
            end
          )

        true ->
          dsl
      end

    {%{reference | kind: definition["interface"]["kind"], definition: definition}, dsl}
  rescue
    error ->
      raise DslError,
        module: Transformer.get_persisted(dsl, :module),
        path: [:domain, :reference, reference.name],
        message: Exception.message(error),
        location: Spark.Dsl.Entity.anno(reference)
  end
end

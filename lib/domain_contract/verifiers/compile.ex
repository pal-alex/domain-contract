defmodule DomainContract.Verifiers.Compile do
  @moduledoc false
  alias DomainContract.Domain
  alias DomainContract.Entity
  alias DomainContract.Operation
  alias DomainContract.Reference
  alias DomainContract.UI.Message
  alias Spark.Dsl.Transformer
  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl) do
    get = fn key -> Transformer.get_option(dsl, [:contract], key) end
    items = Transformer.get_entities(dsl, [:contract])

    owner = %Domain{
      module: Transformer.get_persisted(dsl, :module),
      version: get.(:version),
      responsibility: get.(:responsibility),
      description: get.(:description),
      metadata: get.(:metadata),
      entities:
        Enum.filter(
          items,
          &(is_struct(&1, Entity) or
              match?(%DomainContract.DeclarationReference{kind: :entities}, &1))
        ),
      operations: Enum.filter(items, &is_struct(&1, Operation)),
      consumes: Enum.filter(items, &is_struct(&1, Reference)),
      subscriptions:
        Enum.filter(items, &match?(%Message{module: module} when not is_nil(module), &1)),
      commands: Enum.filter(items, &match?(%Message{module: nil, kind: :command}, &1)),
      notifications: Enum.filter(items, &match?(%Message{module: nil, kind: :notification}, &1))
    }

    {owner, dsl} = DomainContract.Verifiers.Compose.compose(dsl, owner)

    public = DomainContract.Info.contract(%{owner | consumes: [], subscriptions: []})

    resolve = fn module ->
      if module == owner.module, do: public, else: Reference.resolve(module)
    end

    owner = %{
      owner
      | consumes:
          Enum.map(owner.consumes, fn ref ->
            %{ref | definition: DomainContract.Schemas.select(resolve.(ref.module), ref.only)}
          end),
        subscriptions:
          Enum.map(owner.subscriptions, fn ref ->
            %{
              ref
              | definition: DomainContract.Schemas.notification(resolve.(ref.module), ref.name)
            }
          end)
    }

    sources =
      items
      |> Enum.filter(
        &(is_struct(&1, Reference) or
            is_struct(&1, DomainContract.DeclarationReference) or
            match?(%Message{module: module} when not is_nil(module), &1))
      )
      |> Enum.flat_map(&Reference.sources(&1.module))
      |> Enum.uniq()

    dsl =
      Enum.reduce(sources, dsl, fn path, dsl ->
        Transformer.eval(dsl, [], quote(do: @external_resource(unquote(path))))
      end)

    artifact = DomainContract.Info.contract(owner)

    case DomainContract.Artifact.validate(artifact) do
      :ok ->
        :ok

      error ->
        raise ArgumentError,
              "invalid inline contract #{inspect(owner.module)}: #{inspect(error)} #{inspect(DomainContract.Artifact.invalid_types(artifact))}"
    end

    {:ok,
     Transformer.eval(
       dsl,
       [],
       quote do
         @domain_contract_base unquote(Macro.escape(artifact))
         @contract_operations unquote(Enum.map(owner.operations, &to_string(&1.name)))
       end
     )}
  end
end

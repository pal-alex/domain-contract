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
      operations:
        Enum.filter(
          items,
          &(is_struct(&1, Operation) or
              match?(%DomainContract.DeclarationReference{kind: :operations}, &1))
        ),
      consumes: Enum.filter(items, &is_struct(&1, Reference)),
      subscriptions:
        Enum.filter(items, &match?(%Message{module: module} when not is_nil(module), &1)),
      commands: Enum.filter(items, &match?(%Message{module: nil, kind: :command}, &1)),
      notifications: Enum.filter(items, &match?(%Message{module: nil, kind: :notification}, &1))
    }

    {owner, dsl} = DomainContract.Verifiers.Compose.compose(dsl, owner)

    owner = %{
      owner
      | consumes:
          Enum.map(owner.consumes, fn ref ->
            %{ref | definition: Reference.resolve(ref.module)}
          end),
        subscriptions:
          Enum.map(owner.subscriptions, fn ref ->
            provider = Reference.resolve(ref.module)

            event =
              Enum.find(provider["notifications"], &(&1["name"] == to_string(ref.name))) ||
                raise ArgumentError, "unknown notification #{inspect(ref.module)}.#{ref.name}"

            %{
              ref
              | definition: %{
                  "module" => provider["module"],
                  "name" => to_string(ref.name),
                  "payload" => event["payload"],
                  "entities" => provider["entities"]
                }
            }
          end)
    }

    artifact = DomainContract.Info.contract(owner)

    case DomainContract.Artifact.validate(artifact) do
      :ok ->
        :ok

      error ->
        raise ArgumentError, "invalid inline contract #{inspect(owner.module)}: #{inspect(error)}"
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

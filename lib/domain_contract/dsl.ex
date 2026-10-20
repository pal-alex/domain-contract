defmodule DomainContract.Dsl do
  @moduledoc false
  alias DomainContract

  @field %Spark.Dsl.Entity{
    name: :field,
    target: DomainContract.Field,
    args: [:name, :type],
    schema: [
      name: [type: :atom, required: true],
      type: [type: :any, required: true],
      optional: [type: :boolean, default: false],
      description: [type: :string]
    ]
  }

  @entity %Spark.Dsl.Entity{
    name: :entity,
    target: DomainContract.Entity,
    args: [:name],
    schema: [name: [type: :atom, required: true], description: [type: :string]],
    entities: [fields: [@field]]
  }

  @operation %Spark.Dsl.Entity{
    name: :operation,
    target: DomainContract.Operation,
    args: [:name],
    schema: [
      name: [type: :atom, required: true],
      input: [type: :atom],
      output: [type: :atom],
      input_type: [type: :any],
      output_type: [type: :any],
      optional_output: [type: :boolean, default: false],
      description: [type: :string]
    ],
    entities: [
      inputs: [%{@entity | name: :input_entity}],
      outputs: [%{@entity | name: :output_entity}]
    ]
  }

  @types %Spark.Dsl.Entity{
    name: :types,
    target: DomainContract.DeclarationReference,
    args: [:module],
    modules: [:module],
    schema: [module: [type: :atom, required: true]],
    auto_set_fields: [kind: :entities]
  }

  @operations %Spark.Dsl.Entity{
    name: :operations,
    target: DomainContract.DeclarationReference,
    args: [:module],
    modules: [:module],
    schema: [module: [type: :atom, required: true]],
    auto_set_fields: [kind: :operations]
  }

  @dependency %Spark.Dsl.Entity{
    name: :consumes,
    target: DomainContract.Reference,
    args: [:module],
    schema: [module: [type: :atom, required: true], optional: [type: :boolean, default: false]]
  }
  @subscription %Spark.Dsl.Entity{
    name: :subscribe,
    target: DomainContract.UI.Message,
    args: [:module, :name],
    schema: [module: [type: :atom, required: true], name: [type: :atom, required: true]]
  }
  @message %Spark.Dsl.Entity{
    name: :command,
    target: DomainContract.UI.Message,
    args: [:name],
    schema: [
      name: [type: :atom, required: true],
      payload: [type: :any, default: %{}],
      description: [type: :string]
    ]
  }
  @contract %Spark.Dsl.Section{
    name: :contract,
    after_define: {DomainContract.Dsl, :single_contract},
    schema: [
      version: [type: :pos_integer, required: true],
      responsibility: [type: :string, required: true],
      description: [type: :string],
      metadata: [type: :map, default: %{}]
    ],
    entities: [
      @entity,
      @types,
      @operation,
      @operations,
      @dependency,
      @subscription,
      @message,
      %{@message | name: :emit, auto_set_fields: [kind: :notification]}
    ]
  }
  @declarations %Spark.Dsl.Section{name: :declarations, entities: [@operation, @entity]}
  def single_contract do
    quote do
      if Module.get_attribute(__MODULE__, :domain_contract_declared) do
        raise ArgumentError, "exactly one contract block is allowed per public module"
      end

      @domain_contract_declared true
      DomainContract.Compiler.prepare_operations(__MODULE__)
    end
  end

  use Spark.Dsl.Extension,
    sections: [@contract, @declarations],
    transformers: [DomainContract.Verifiers.Compile]
end

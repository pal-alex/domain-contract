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

  @interface %Spark.Dsl.Entity{
    name: :interface,
    target: DomainContract.Interface,
    args: [:kind],
    schema: [
      kind: [type: :any, required: true],
      name: [type: :any, required: true],
      version: [type: :any, required: true],
      description: [type: :string]
    ],
    entities: [operations: [@operation, @operations]]
  }

  @domain %Spark.Dsl.Entity{
    name: :domain,
    target: DomainContract.Domain,
    args: [:name],
    schema: [name: [type: :atom, required: true], description: [type: :string]],
    entities: [
      interfaces: [@interface],
      consumes: [
        %Spark.Dsl.Entity{
          name: :consumes,
          target: DomainContract.Reference,
          args: [:name],
          schema: [
            name: [type: :string, required: true],
            version: [type: :pos_integer, required: true],
            contract: [type: :any, required: true],
            kind: [type: :any],
            optional: [type: :boolean, default: false]
          ]
        }
      ],
      implements: [
        %Spark.Dsl.Entity{
          name: :implements,
          target: DomainContract.Reference,
          args: [:name],
          schema: [
            name: [type: :string, required: true],
            version: [type: :pos_integer, required: true],
            contract: [type: :any, required: true],
            kind: [type: :any]
          ]
        }
      ],
      entities: [@entity, @types]
    ]
  }

  @contract %Spark.Dsl.Section{
    name: :contract,
    top_level?: true,
    entities: [@domain]
  }

  @declarations %Spark.Dsl.Section{
    name: :declarations,
    entities: [@operation, @entity]
  }

  # Spark consumes the entity/section definitions above when expanding this use.
  # credo:disable-for-next-line Credo.Check.Readability.StrictModuleLayout
  use Spark.Dsl.Extension,
    sections: [@contract, @declarations],
    transformers: [DomainContract.Verifiers.Compile],
    verifiers: [DomainContract.Verifiers.Validate]
end

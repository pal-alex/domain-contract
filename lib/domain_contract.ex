defmodule DomainContract do
  @moduledoc """
  The normative public API and behavioral rules of a domain, declared at compile time.

  Typed declarations define the public structure. Their `description` values define
  behavioral obligations for implementations and callers: domain ownership and
  boundaries, entity identity and invariants, interface scope, operation preconditions,
  effects, results, replay and failure semantics, and field meaning beyond its type.
  Keep these rules in the existing contract and its fragments; general documentation
  explains the architecture and links to the owning contract.

  Compilation verifies declaration structure and references. `DomainContract.call/4`
  validates input/output shapes through `DomainContract.Runtime`, but neither
  check proves compliance with prose guarantees. Implementations and behavioral tests
  must uphold those guarantees. A mismatch is a contract/implementation defect to
  resolve explicitly, not a reason to treat the description as optional commentary.

  Declare one domain with named interfaces, entities, fields and operations. Inputs
  and outputs can reference shared entities or declare a named schema beside the
  operation. Field types reference domain entities with `{:entity, name}` and compose
  lists with `{:list, type}` or dictionaries with `{:dictionary, type}`.

  Use `{:enum, ["queued", "running"]}` for a closed set of strings and
  `{:variant, %{"event" => {:entity, :event}, "result" => :opaque}}` for a tagged
  value with exactly `"type"` and `"data"` keys. The selected tag determines the
  data type; foreign `:opaque` data is still never inspected. `:json_scalar`
  accepts a string, number, boolean or explicit null without encoding it again.
  These types compose inside lists, dictionaries and variants. Exports using them
  have format version 2; declarations using only the original types retain v1.

      operation :get do
        description "Read an item by its identity; absent items return no value."
        input_entity :item_lookup do
          field :id, :string
        end
        output :item
        optional_output true
      end

  `output_entity :name do ... end` declares a local output in the same way. Choose
  exactly one reference, local entity or explicit `input_type`/`output_type` for each
  side. For example, `output_type {:list, :string}` preserves a list result and
  `output_type :null` accepts only nil. Explicit types use the field type algebra,
  including nested entity references; they do not wrap or transform business values.
  Typed roots and `:null` use export format v5, including their consumers and replacements.
  Local names remain domain-wide
  semantic type names, so collisions fail compilation instead of being renamed.

  Split declarations with `use DomainContract.Fragment` and a
  `declarations do` block. A type fragment contains entities; an operation fragment
  contains one or several related operations. The root domain composes them with
  `types MyDomain.Types` and, inside an interface, `operations MyDomain.Get`.
  Shared references resolve against the whole domain, retaining Spark source metadata.
  Inline and composed declarations compile into the same verified canonical model.

  `:opaque` is foreign payload: the domain may store and forward it, but must not inspect,
  index, filter or derive behavior from its contents. This declaration documents that
  obligation; it does not install a runtime validator or enforce payload access.

  Use `DomainContract.Info.contract/1` for a deterministic, source-independent
  representation including descriptions at every level. Canonical JSON is an export
  of this same contract, not a separate source of behavioral rules. Interface versions
  describe the declared surface; plugin manifests and dispatch control runtime
  registration and must agree with the applicable contract.

  See `README.md` for provider, consumer and test-adapter examples.
  """

  use Boundary,
    top_level?: true,
    type: :strict,
    deps: [Spark, Jason, Mix],
    exports: [
      Artifact,
      Compatibility,
      Context,
      {Dsl, []},
      Fragment,
      Implementation,
      Info,
      Reference,
      Runtime,
      Source,
      Stub,
      Domain,
      Entity,
      Field,
      Interface,
      Operation,
      DeclarationReference
    ]

  use Spark.Dsl, default_extensions: [extensions: [DomainContract.Dsl]]

  @doc """
  Invokes a declared dependency against its immutable contract reference.

  The adapter supplies a `DomainContract.Context` (or embeds it in
  `:domain_contract`). Input and successful output are validated around dispatch;
  application errors pass through unchanged. Library failures are
  `{:error, {:invalid_contract, reason}}`. An adapter reports an absent dependency
  as `{:error, {:unavailable, name}}`, including for optional dependencies.
  """
  def call(context, name, operation, input),
    do: DomainContract.Port.call(context, name, operation, input)
end

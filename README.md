# DomainContract

An application-independent Elixir library for public domain interfaces, exact contract
references, implementation conformance and validated invocation. It depends on Spark
and Jason, with no platform, transport, storage engine or runtime registry.

One contract defines one versioned public interface. Implementations reference that
interface; consumers reference the same immutable definition. Schemas and descriptions
stay in the authoritative declaration. Descriptions express behavioral obligations;
structural checks do not prove business correctness, authorization or durability.

Add `{:domain_contract, git: "https://github.com/pal-alex/domain-contract.git"}` to
`mix.exs` and pin the exact published revision in the application's dependency lock.

## Declare and reference contracts

```elixir
defmodule Tasks.Contract do
  use DomainContract

  domain :tasks do
    interface :capability do
      name "tasks"
      version 2

      operation :get do
        input_entity :lookup do
          field :id, :string
        end
        output_entity :task do
          field :id, :string
          field :title, :string
        end
      end
    end
  end
end

defmodule Chat.Contract do
  use DomainContract

  domain :chat do
    consumes "tasks", version: 2, contract: Tasks.Contract
  end
end
```

`contract:` accepts a declaration module, a canonical export map, or a JSON file
containing an export or list of exports. Independent packages should reference the
immutable JSON artifact, for example `contract: Path.expand("../contracts/tasks.json", __DIR__)`.
They need no provider implementation module. JSON resources and source modules are
tracked for recompilation. `kind:` disambiguates interfaces with the same name in a
source bundle. Referenced versions must match exactly.

Interface identity includes `kind` and `name`. Distinct kinds with the same name
may coexist in a deployment; each consumer context binds exactly one kind for that
invocation name. Runtime adapters select providers by the full reference, including
version and snapshot, rather than by a matching name/version alone. Target selection
remains the runtime's responsibility; the library has no server or runner concept.

`consumes` has no operation block or local schemas. A consumer may call every operation
in the referenced interface. `optional: true` allows an absent provider during candidate
validation; if present, it must conform exactly. Dispatch reports an absent dependency
as `{:error, {:unavailable, name}}`. An undeclared dependency is always a contract error.

A new public capability uses `interface`, entities and operations as above. Shared types
and operations may be composed from `DomainContract.Fragment` modules using `types`
and `operations`. Entities support primitives, entity references, lists, dictionaries,
enums, variants and opaque payloads. See the module documentation for their semantics.

Operations can preserve scalar, list or nil results without adding response envelopes:

```elixir
operation :head, input: :empty_request, output_type: :string
operation :paths, input: :empty_request, output_type: {:list, :string}
operation :pricing, input: :empty_request, output_type: {:list, {:entity, :rate}}
operation :clean, input: :empty_request, output_type: :null
operation :echo, input_type: :string, output_type: :string
```

`input_type` and `output_type` use the field type algebra, including nested entity
references. Choose exactly one named entity, local entity or explicit type for each
side. `:null` accepts only nil; `optional_output: true` additionally allows nil for
an otherwise typed result. Lists validate every element and entities reject unknown
fields. Use the actual business shape; opaque payloads are for deliberately uninspected
foreign values. Typed roots and `:null` require export format v5, including when
referenced by another declaration. Existing declarations keep their original exports.

## Implement the complete interface

The default implementation binds to its authoritative declaration:

```elixir
defmodule Tasks do
  use DomainContract.Implementation, contract: Tasks.Contract

  def call("get", %{"id" => id}, _context) do
    {:ok, %{"id" => id, "title" => "Example"}}
  end
end
```

An independently packaged replacement references the existing contract:

```elixir
defmodule UserTasks.Contract do
  use DomainContract

  domain :user_tasks do
    implements "tasks", version: 2,
      contract: Path.expand("../contracts/tasks.json", __DIR__)
  end
end

defmodule UserTasks do
  use DomainContract.Implementation, contract: UserTasks.Contract

  def call("get", %{"id" => id}, _context) do
    {:ok, %{"id" => id, "title" => "User implementation"}}
  end
end
```

The compiler checks public `call/3` coverage of the whole interface. Literal operation
heads and finite `operation in [...]` guards establish entry-point presence. A generic
router can use the automatically derived `@contract_operations` guard instead of
repeating a list; compiler-expanded Erlang equality/boolean guards are also recognized.
`contracts: [A.Contract, B.Contract]` binds a multi-interface provider.
The callback body and behavioral correctness remain the implementation author's responsibility.

`Implementation.check(provider, exported_declarations)` verifies loaded entry-point
metadata against the package's declarations. The generated `__domain_contracts__/0`
and `__domain_contract_operations__/0` contain immutable snapshots and checked entry
points. Package tooling must include and verify these alongside the actual compiled
entry point; a JSON declaration alone is not evidence of an implementation.
`Implementation.check_beam(binary, exported_declarations)` checks the exact package
entry point's persisted metadata and exports without loading or activating its code.
`Compatibility.validate(exported_declarations)` checks the package's complete embedded
snapshots and rejects conflicting definitions without requiring installed providers or
an authority catalog. It does not authenticate their origin or establish availability;
deployment checks still compare the selected candidate with independent authoritative
artifacts through `Compatibility.check/2`.

## Invoke through a trusted context

```elixir
context = DomainContract.Context.new(Chat.Contract, "chat", fn
  "tasks", operation, input, context -> Tasks.call(operation, input, context)
  name, _operation, _input, _context -> {:error, {:unavailable, name}}
end)

DomainContract.call(context, "tasks", "get", %{"id" => "one"})
```

The runtime adapter binds the consumer and trusted caller when it creates the context.
It must not derive caller identity from arbitrary request parameters. A platform context
may embed this binding as `:domain_contract`; dispatch then receives the original outer
context, preserving transport state and scoped execution metadata. Static maps, dynamic
provider discovery and injected test dispatchers use the same API.

`DomainContract.call/4` verifies the dependency and operation, validates the input,
dispatches, and validates the complete successful output. Unknown fields are rejected
on both sides; there are no consumer-specific projections. Application errors pass
through unchanged. Library failures use `{:error, {:invalid_contract, reason}}`.
Context construction validates and captures the consumer artifact once. Candidate-wide
compatibility and digest checks belong to build/activation, not every business call.

`Runtime.input/4` and `Runtime.output/4` validate an explicit provider interface from a
module or export. Their three-argument forms support declarations with unique operation
names. `Stub.dispatcher/2` creates a four-argument dispatcher with the same validation;
use it with `Context.new/3` and `DomainContract.call/4` in tests.

Provider discovery, authorization, isolation, plugin lifecycle, storage namespace ownership,
transport and execution/recovery guarantees remain runtime/SDK responsibilities.
DomainContract creates no processes or registries. A shared BEAM VM is trusted
infrastructure, not a security sandbox. Runtime adapters must verify storage compatibility
before restoring a previous provider; replacing code does not roll back persistent data.

## Export and check exact candidates

`Info.contract/1` returns deterministic declarations; `Info.json/1` exports them.
Existing authoritative declarations retain format v1/v2. References use format v4 and embed an
interface snapshot, its reachable entities, the domain description and a SHA-256 digest.
Declarations containing or referencing typed roots or the nil-only type use format v5.
Descriptions at every level participate in this identity. Legacy v3 consumer projections are rejected. A digest identifies an
artifact; it does not authenticate its origin. The package catalog supplies trusted,
immutable authoritative definitions, independently of the candidate implementation.

```sh
mix domain.contract Tasks.Contract --output tasks.json
mix domain.export --output priv/domain_contracts.json
mix domain.check --authority tasks.json candidate.json consumer.json
```

`domain.export` exports only the current application's root declarations, without
starting it. `Compatibility.check(candidates, authorities)` rejects unknown contracts,
missing required providers, duplicate providers, conflicting definitions and incorrect
versions. Optional providers may be absent. Candidate definitions are checked against
the supplied authorities; references cannot invent contracts. Include exact packaged
revisions and their authoritative exports, not unrelated local source trees. SDK tooling
derives platform dependency metadata and verifies package/runtime compatibility.

DomainContract exports public modules explicitly through Boundary. Contract boundaries
should depend on DomainContract and Spark without inheriting implementation services.
Implementation boundaries expose only their public entry points; cross-domain calls
use `DomainContract.call/4`. Compile with warnings as errors to enforce Boundary.

Run `mix verify` for formatting, strict compilation and tests, as normal CI does.
Tests include interchangeable implementations, package metadata conformance, full
interface coverage, immutable file references and negative architecture cases.

For private Git dependencies, run `mix domain.vendor` in an authenticated build checkout
before creating a Docker context. It materializes the exact locked revision in
`vendor/domain_contract`, excluding credentials and Git metadata. Applications may use
that directory in source bundles and their pinned Git dependency in ordinary checkouts.

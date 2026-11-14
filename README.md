# DomainContract

A public Elixir module owns one inline contract. Its identity is its module name.
A consumer names the module and the operations it needs, capturing their compiled schemas.
Version numbers and digests identify history; directional structural checks decide
replacement compatibility. Responsibility and description changes require review:
compilation cannot prove behavioral equivalence or semantic cohesion.

```elixir
defmodule MyApp.Items do
  use DomainContract

  contract do
    version 1
    responsibility "Owns item lookup and lifecycle; does not own billing."

    operation :get do
      input_entity :lookup do
        field :id, :integer
      end
      output_type {:nullable, :string}
    end
  end

  def call("get", %{id: id}, context), do: MyApp.Items.Persistence.get(id, context)
end

defmodule MyApp.Checkout do
  use DomainContract

  contract do
    version 1
    responsibility "Owns checkout orchestration."
    consumes MyApp.Items, only: [:get]
  end

  def lookup(id), do: DomainContract.call(MyApp.Items, :get, %{id: id})
end
```

Calls validate declared dependencies, operation inputs, successful outputs and
application errors. Declare `error_type` for every expected failure; its default
`:never` means the operation cannot return an application error. Framework invocation
failures remain separate from the provider error schema. An entry adapter raises
`DomainContract.InvocationError` when delivery or owner-context admission fails;
Runtime returns its reason as `{:error, reason}`. Business failures must use the
declared error schema. Local calls execute the public owner's
`call/3`. Plain local calls validate the inline captured requirements without
registering schemas in a runtime store. A missing local dependency returns
`{:error, {:unavailable, Module}}`. A trusted platform creates
`DomainContract.Context.new(consumer, trusted_caller)` after registering the
selected schema index, then binds it with
`DomainContract.with_context(context, fn -> ... end)`. Calls always enter the
installed public module's `call/3`; a platform packager may install a transport
adapter with the same public name. DomainContract does not select transports.
`DomainContract.invoke(context, Module, operation, input)` is the explicit context
form for captured execution contexts and runtime adapters. A platform context may
embed the binding in its `:domain_contract` field; the complete platform value,
including authorization, source and execution scope, reaches the transport.
Contexts are trusted runtime inputs, never browser/request parameter identities.
Process bindings do not propagate to Tasks: capture and bind them explicitly.

Private helpers use `use DomainContract.Owned, owner: MyApp.Checkout` to inherit
lexical ownership. Type fragments remain available for shared data definitions;
operations must be declared by their owner and cannot be imported from a fragment. Field optionality
permits omission only; explicit null requires `{:nullable, type}` or a union with
`:null`. Entities reject unknown keys and default to atom keys; declare
`keys :strings` inside an entity for JSON inputs. Literal map types preserve their
atom or string keys: `%{id: :integer}` and `%{"id" => :integer}` are different
contracts. Mixed key types are rejected, and validation never converts payloads.

Use typed lists, dictionaries, tuples, unions, enums and variants. `:opaque`, `:any`,
untyped `:map`/`:list`, and open entities are rejected. Application structs require
`{:struct, Module, %{field: type, ...}}` with every field declared. Date, Time,
NaiveDateTime and DateTime have built-in ISO calendar shapes and value validation.
Do not pass a database record when an operation only needs a few projected fields.

### Selecting and reusing entity definitions

Inside `contract do`, use `types(Module, only: [:task, :project])` to copy selected
entities and their transitive entity dependencies into the consumer's format 9
schema. `Module` may be a declaration fragment or a public owner. Names, field
optionality, types and descriptions are preserved. This imports values only:
it adds no operations, `consumes` permissions or runtime schema references.

```elixir
defmodule MyApp.Consumer do
  use DomainContract
  require MyApp.LocalTypes # orders compilation of a selected local fragment

  contract do
    version 1
    responsibility "Owns consumer-specific behavior."
    types(MyApp.LocalTypes, only: [:request])
    types(MyApp.Tasks, only: [:task])
  end
end
```

For public owners, configure explicit JSON/BEAM inputs with
`:domain_contract, :metadata_paths` (as below), or make the already compiled owner
BEAM available on the code path. Resolution uses
`DomainContract.Reference.resolve_metadata/1`: it never loads the owner or calls
its metadata functions. Already compiled in-memory owners are read through persisted attributes. Missing, invalid or conflicting owner metadata and unknown selection roots
fail compilation. Explicit metadata takes precedence over code-path metadata.
Recompile consumers when their selected metadata inputs change.

For selected fragments, `require Fragment` before the contract when the fragment
is compiled in the same build; this makes compilation order explicit without
loading an unclassified public owner. Already loaded or code-path fragments need
no extra ordering. The existing `types(Fragment)` still imports all declarations;
Operations must be declared inline by their owner. Public-owner imports require `only:`.

Fragment selections are resolved together, independent of import order. Each root
must exist in its named fragment, but its dependencies may come from any other
composed fragment or inline entity. `types(Fragment, only: [])` contributes no
roots but makes its declarations available to other fragment roots. Unreachable
fragment entries are pruned before validation. Owner dependencies are selected
within that owner's metadata; consumer definitions cannot replace them. Reachable
duplicate names fail even if definitions match. Import each source once, combining
its roots in one `only:` list. Cyclic entity references are supported.

## Independent builds and replacement

`DomainContract.Artifact.from_beam(bytes)` reads persisted canonical metadata
without loading or executing provider code. Independent consumers configure
`:domain_contract, :metadata_paths` with explicit JSON/BEAM build inputs. Artifacts
carry the canonical module identity and originate from the owner's compiled export.
Provider implementation BEAMs are never generated or packaged with a consumer.
Missing or ambiguous inputs fail compilation. Metadata paths are build inputs,
not a mutable runtime provider registry. The runtime still owns package provenance,
authorization, transport routing, isolation and safe hot replacement.

`DomainContract.Compatibility.satisfies(provider, retained_requirements)` checks
inputs contravariantly and outputs/errors/notifications covariantly, including closed
structures, required/optional fields and enums. New optional input props and new
operations are compatible; newly required inputs and removed required operations
are incompatible. New output fields can break a closed receiving schema.
Only selected operations/commands and their reachable entities are captured.
Unrelated provider changes do not expand consumer requirements or permissions.
Arbitrary implementation behavior is not inferred from code or from digests.

## Phoenix UI

```elixir
defmodule MyAppWeb.Editor do
  use Phoenix.LiveComponent
  use DomainContract.UI, entry: :live, prop_modes: [editable?: :controlled],
    prop_types: [source: %{id: :integer}]

  contract do
    version 1
    responsibility "Owns item editing and validation; does not own navigation."
    consumes MyApp.Items, only: [:get]
    command :request_close
    emit :changed, payload: %{id: :integer, change: {:enum, [:created, :updated]}}
  end

  attr :id, :string, required: true
  attr :source, :map, required: true
  attr :editable?, :boolean, default: true
  slot :inner_block
  def live(assigns), do: # ordinary Phoenix wrapper

  # During update, register the mounted module/instance after assigning its ID:
  # socket = DomainContract.UI.mount(socket, __MODULE__, socket.assigns.id)
  # Public delivery calls handle_command(name, payload, socket), returning socket.
  # Ordinary assign updates retain Phoenix update/2 semantics.
end
```

Use native Phoenix `attr`/`slot` once; their diagnostics remain intact. Metadata
includes initial/controlled props and slots, not internal socket assigns. Refine
Phoenix container attributes using `prop_types`; untyped public props are rejected. Dynamic
boundaries can call `DomainContract.UI.validate_props/2`. One public function
component per module is selected with `entry:`; render/private helpers are not
additional public surfaces.

A command caller declares `consumes MyAppWeb.Editor`, then calls
`DomainContract.UI.command({MyAppWeb.Editor, editor_id}, :request_close, %{})`.
The emitter calls `DomainContract.UI.emit(socket, :changed,
%{id: 42, change: :updated})`, receiving `{:ok, socket}`. It never selects recipients.
A subscriber declares `subscribe MyAppWeb.Editor, :changed` and implements
`handle_notification(emitter, name, payload, socket)`. Subscription alone requires
no `consumes` and cannot issue commands.

Attach `on_mount DomainContract.UI` to the parent LiveView. Register active child
instances with `mount/3` and unregister them with `unmount/2` when removing them.
The owning parent must perform this removal because Phoenix LiveComponents have
no public unmount callback. LiveViews register automatically; function components
and hooks can register a `:context` participant using their parent LiveView's
socket. Several instances are addressed separately. Participants and opaque relay
tokens belong only to that process and disappear when it terminates. Delivery to
an unmounted command target returns an error; notifications reach active registered
subscribers only. This is neither a durable event bus nor an iframe postMessage
transport. Acceptance does not imply command completion. Normal `send_update`
assign updates remain valid; reserved command/notification bypasses are diagnostics.

## Metadata and runtime lifetime

Format 9 exports contain a `contracts` list of owner/dependency declarations and
one `schemas` index keyed by executable public schema. Private `metadata`, owner
responsibility and documentation remain on owner descriptors and are excluded from
this identity. `Schemas.unbundle/1` restores the full reviewed owner declaration. A dependency contains `module`,
`schema` and `optional`; a subscription adds the event `name`. Self references
resolve to the owner's definition. `mix domain.export` derives this bundle from
persisted BEAM attributes without activating provider code. Implementation metadata
names the primary owner instead of repeating its artifact.

Compilation resolves external dependencies only against explicitly selected metadata
inputs. Midva stores those in `priv/domain_inputs.json`. Package admission verifies
the exact checksum, source BEAM metadata and the selected graph. A version or digest
never substitutes for directional compatibility. Module/version pairs are not frozen
across unrelated historical installations.

Trusted contexts capture caller identity and compact declaration references. They do
not retain schema revisions. A binding scope only sets the current process context
and restores its predecessor on return or failure; Tasks receive contexts explicitly.
The trusted installer registers its selected schemas with `SchemaStore.replace/2`
before admitting calls and replaces that set after successful activation. Prepared
metadata has its own explicit registration lifetime; UI schemas belong to the installed
composition too. Mounted participants do not retain old revisions.
No per-scope, worker or service lease is created. Compatibility checks cover the
selected composition and its independently captured consumer requirements, rather
than historical live executions. Older requirement schemas still used by an
installed consumer remain part of that composition.

Hot replacement keeps one active provider per public module. An existing scope's
next call can reach the new compatible implementation. An already running call is
not restarted or replayed. Captured contexts keep their original declarations and
never acquire additional dependencies from updated code. If their required schemas
are no longer available, invocation returns `{:error, {:invalid_contract,
:expired_context}}`; successful continuation across arbitrary updates is not promised.
Each invocation selects its dependency, operation and entity index once for both
input and output. `__contract_entry__/0` captures the schema and local `call/3`
from one code generation, preventing a concurrent update from redirecting checked
input to incompatible code. Bound calls approve compatible installed schema pairs
with `SchemaStore.approve/2`, caching the result for their installation lifetime.
Plain local calls validate selected requirements against the captured provider;
identical schemas need no structural comparison or store.
`Context` contains consumer, trusted caller and required schema references only.
Platform execution IDs, authorization grants and storage belong to the embedding
context. `Info.declaration/3` creates trusted synthetic declarations;
`Info.binding/1` projects canonical requirements. Already validated adapters may
use `Context.captured/2`; none of these operations retain schemas. Runtime calls
accept format 9 only; old metadata must be rebuilt from migrated source before
admission. Key representation and error types cannot be inferred from an old export. Code rollback is checked against current consumers and data and never
repeats effects automatically.

## Architecture review

Check operation boundaries in a compiled application:

```sh
mix domain.check --application my_app --strict
```

Providers implement their declared operations through `call/3`; consumers declare
`consumes(MyApp.Inventory, only: [:fetch])` and use `DomainContract.call(MyApp.Inventory, :fetch, input)`.
The raising form `call!/3` returns the successful value and raises on operation or
validation errors. Both forms use the same validation and captured requirements.
Direct cross-owner calls to `Inventory.call/3`, helpers or structs are rejected.
There is no parallel native API and no `native`, `uses`, `exports` or `gateways`
metadata. Old declarations fail compilation instead of silently losing enforcement.

An owner owns its namespace. `metadata(%{architecture: %{owns: [OtherNamespace]}})`
adds namespaces. `use DomainContract.Owned, owner: MyApp.Inventory` assigns private
helpers outside that namespace; helpers inherit the owner's dependencies.
A private consumer-only declaration may use `Owned` to keep local requirements
while belonging to its parent. It cannot publish operations or expose a second API.
Ordinary Elixir functions remain usable inside an owner. Phoenix function
components expose their declared props, while behaviour callbacks remain runtime
entry points, not cross-owner domain APIs.

The checker reads BEAM debug AST without starting the application. Aliases,
delegates, captures, literal `apply` and struct references are checked after
expansion. Literal operation inputs are checked against the declared schema;
computed inputs and outputs are validated at runtime. Missing debug info and
unresolved native dynamic dispatch fail, including in consumer-only declarations.
`invoke/4` can address a dynamic operation through a trusted captured context;
its requirements, input and results are always validated at runtime. Literal
addresses also receive the static dependency and input checks.
Transport adapters use `Runtime.dispatch/5` to retain `{:failure, reason}` for
admission, validation and delivery failures, separately from the owner's typed
`{:error, reason}`. Ordinary `call` and `invoke` retain their two-result API. `--strict` additionally requires every module
to have an owner. `--exclude-dir test/support` excludes an explicit source directory.
Dependency owners are discovered without checking their implementation bodies.

The equivalent API is `DomainContract.Architecture.check_application(:my_app,
strict: true)`. It returns `:ok` or `{:error, diagnostics}` with source locations.
Entry adapters may generate constant metadata functions; executable wrappers
remain checked. Erased macros, arbitrary message protocols and whole-program
data flow are outside the static check.

The executable [golden-path fixture](test/fixtures/architecture/lib/example.ex)
and its mutation tests exercise two owners communicating through one operation.
To run the fixture from a clean build:

```sh
cd test/fixtures/architecture
mix deps.get
mix domain.check --application architecture_example --strict
```

`mix domain.export --output architecture.json` exports owner BEAM metadata without
starting the application. `mix domain.diff before.json after.json --json review.json`
produces readable and machine reports, separating compatible and incompatible
changes. Add `--sources 'lib/**/*.ex'` (repeatable) to include source boundary
diagnostics; proven bypasses fail the command and review warnings remain advisory. `mix domain.check --declarations architecture.json` validates artifacts;
`mix domain.check candidates.json` validates the selected providers/dependencies.

```text
Architecture changes

Compatible changes
+ Elixir.MyAppWeb.Payments subscriptions: changed
+ Elixir.MyAppWeb.Editor commands: changed

Incompatible changes
! Elixir.MyApp.Items operations: changed
```

Only public declarations enter diffs. Source diagnostics identify explicit reserved
UI delivery and potential private owner calls. Forwarding all assigns in HEEx emits
a prop propagation warning; growing a surface with at least 20 operations plus
dependencies emits a composition warning. These are review heuristics, not errors.
These source-only review heuristics do not resolve aliases or dynamic dispatch;
the compiled application check above is separate. Business cohesion and prose
obligations require human review and behavioral tests. Boundary continues to enforce
configured implementation boundaries.
Run `mix verify` for formatting, compilation with warnings as errors and all tests.

`string` accepts UTF-8 text; `binary` accepts arbitrary bytes. Use `json` only at
an actual JSON transport or document boundary whose contents belong to another
owner. It rejects structs, atom keys, arbitrary atoms, tuples and runtime handles.
Describe business records with fields and entities instead of replacing `opaque`
with `json` everywhere. Errors are part of each operation's schema; the default
`never` means that operation does not return a business error.

Version 2.0 uses format 9. Rebuild providers, consumers and their exports together.
Remove architecture bypass declarations, operation fragments and untyped payloads;
select consumed operations, declare key modes and expected errors. Refresh independent
metadata inputs before compiling consumers. Old executable packages are not upgraded
by changing a JSON version number. The previous format-8 deployment notes are historical.

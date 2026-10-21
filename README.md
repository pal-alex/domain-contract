# DomainContract

A public Elixir module owns one inline contract. Its identity is its module name.
A consumer names the module and captures compiled requirements automatically.
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

  def call("get", %{"id" => id}, context), do: MyApp.Items.Persistence.get(id, context)
end

defmodule MyApp.Checkout do
  use DomainContract

  contract do
    version 1
    responsibility "Owns checkout orchestration."
    consumes MyApp.Items
  end

  def lookup(id), do: DomainContract.call(MyApp.Items, :get, %{id: id})
end
```

Calls validate declared dependencies, operation inputs and successful outputs.
Application errors pass through unchanged. Local calls execute the public owner's
`call/3`. For transports, create `DomainContract.Context.new(consumer, trusted_caller,
dispatch)` and bind it with `DomainContract.with_context(context, fn -> ... end)`.
The dispatcher receives `(target_module, operation_string, input, original_context)`.
`DomainContract.invoke(context, Module, operation, input)` is the explicit context
form for captured execution contexts and runtime adapters. A platform context may
embed the binding in its `:domain_contract` field; the complete platform value,
including authorization, source and execution scope, reaches the transport.
Contexts are trusted runtime inputs, never browser/request parameter identities.
Process bindings do not propagate to Tasks: capture and bind them explicitly.

Private helpers use `use DomainContract.Owned, owner: MyApp.Checkout` to inherit
lexical ownership. Entity/operation fragments remain available for decomposition;
they are private declarations, never competing public contracts. Field optionality
permits omission only; explicit null requires `{:nullable, type}` or a union with
`:null`. Closed entities reject unknown keys. Lists, dictionaries, unions, enums,
variants, opaque values and open entities retain their validation semantics.

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
inputs contravariantly and outputs/notifications covariantly, including closed
structures, required/optional fields and enums. New optional input props and new
operations are compatible; newly required inputs and removed required operations
are incompatible. New output fields can break a closed receiving schema.
The captured declaration conservatively retains its public surface; arbitrary
implementation behavior is not inferred from code or from digests.

## Phoenix UI

```elixir
defmodule MyAppWeb.Editor do
  use Phoenix.LiveComponent
  use DomainContract.UI, entry: :live, prop_modes: [editable?: :controlled]

  contract do
    version 1
    responsibility "Owns item editing and validation; does not own navigation."
    consumes MyApp.Items
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
includes initial/controlled props and slots, not internal socket assigns. Dynamic
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

Format 8 exports contain a `contracts` list of owner/dependency declarations and
one `schemas` index keyed by public revision. A dependency contains `module`,
`schema` and `optional`; a subscription adds the event `name`. Self references
resolve to the owner's definition. `mix domain.export` derives this bundle from
persisted BEAM attributes without activating provider code. Implementation metadata
names the primary owner instead of repeating its artifact.

Compilation resolves external dependencies only against explicitly selected metadata
inputs. Midva stores those in `priv/domain_inputs.json`. Package admission verifies
the exact checksum, source BEAM metadata and the selected graph. A version or digest
never substitutes for directional compatibility. Module/version pairs are not frozen
across unrelated historical installations.

Trusted contexts retain caller identity and compact declaration references. The
runtime schema store retains revisions for current installations, the previous
installation, prepared candidates and monitored live context owners. Replacing an
installation releases completed revisions after their final holder exits. Value
validation selects the operation and its reachable entity declarations. An expired
context fails explicitly; it never borrows a replacement's permissions.

## Architecture review

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
Dynamic dispatch, aliases, business cohesion and prose obligations require human review and
behavioral tests. Boundary continues to enforce configured implementation boundaries.
Run `mix verify` for formatting, compilation with warnings as errors and all tests.

Format transition and coordinated runtime rollout: [format 8 deployment](docs/format-8-deployment.txt).

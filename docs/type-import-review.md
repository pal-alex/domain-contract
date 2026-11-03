# Task 215: selective entity imports and library review

Reviewed base: `8a12cea32006a2749724737104e31d3c896d24e5`.
Scope: all 43 Elixir source files under `lib/`, plus the build, tests and README.
This is a static library review, with executable checks for the import facility.
The proposals below are follow-up work, not additional public API changes in this task.

## Implemented contract

- `types(Fragment)` retains its existing meaning; `operations(Fragment)` is unchanged.
- `types(Fragment, only: [:root, ...])` selects roots and follows entity references across
  the complete composition. Inline and operation-local entities remain roots. An empty
  fragment selection can supply dependencies to roots from another fragment.
- `require Fragment` orders a selected fragment's compilation when it is built concurrently
  with its consumer. Loaded fragments and compiled fragments on the code path also work.
- `types(PublicOwner, only: [:root, ...])` reads explicit JSON/BEAM metadata or the owner's
  existing code-path BEAM through `Reference.resolve_metadata/1`. It does not load owner
  code or invoke `__contract__/0`. In-memory owners must first export their metadata.
- Owner dependencies close within their source metadata. Reachable name collisions fail;
  unknown roots cannot silently resolve from a different import. Import each source once
  and combine multiple roots in its `only:` list.
- Canonical entity maps are copied intact into format 8. Imports confer no `consumes`
  permission, operations, schemas, or dynamic runtime reference. No runtime registry was added.
- Metadata inputs are compile-time snapshots. Recompile consumers after changing those inputs.

The README has executable syntax and build-order guidance. `test/type_import_test.exs`
covers legacy composition, selection, recursive graphs, all reference-bearing containers,
enum literals, cross-fragment pruning, errors, parallel compilation, canonical equality,
validation, missing/ambiguous inputs, JSON/BEAM/code-path loading, and a fresh-VM build.
A provider `@on_load` marker detects unintended code loading. Consumer BEAM imports are
checked for executable provider references; a call without `consumes` must still fail.

## Follow-up proposals

1. **Make metadata resolution policy explicit throughout the library.**
   `lib/domain_contract/reference.ex` has a module description promising no provider activation,
   but legacy `resolve/1` can call a loaded `__contract__/0` or `Code.ensure_compiled/1`.
   `lib/domain_contract/info.ex` also prefers a loaded metadata function. The new
   `resolve_metadata/1` deliberately avoids these fallbacks for type imports. Follow up by
   naming and documenting local executable resolution separately from offline resolution,
   then migrating callers deliberately. Do not silently remove existing same-build behavior.
   Also track explicit metadata paths as compiler inputs if incremental recompilation is
   required; the current resolver reads them without registering `@external_resource`.

2. **Share a grammar-aware entity-reference walker.**
   `lib/domain_contract/schemas.ex` (`referenced/1`, `reachable/3`) recursively scans arbitrary
   lists/maps, including enum values. A literal enum value `["entity", "unused"]` can therefore
   retain an unrelated entity in `type_entities/2` or `operation/2`. It also repeatedly scans
   the entire entity list for successive graph levels. The import walker in
   `lib/domain_contract/verifiers/compose.ex` follows only reference-bearing type constructors
   and indexes names once. A later private helper could serve both projections, with explicit
   missing-name/collision policies. Preserve existing projection output ordering and add enum,
   cycle, missing-reference and large-graph checks before adopting it outside imports.

3. **Unify schema reconstruction without conflating trust levels.**
   `lib/domain_contract/schemas.ex` repeats owner/edge reconstruction in `unbundle/1`,
   `restore_value/2` and `expand/1`. Extract the structural reconstruction into one private
   function while keeping validation and prepared-input admission as separate entry paths.
   Keep ID checks, owner checks, self-reference removal, digest handling and schema lifetime
   visible in the caller. The lifecycle tests should continue checking expired contexts and
   unchanged-schema reuse. Do not merge these into a new runtime registry.

4. **Validate the final UI artifact at a single compiler boundary.**
   `lib/domain_contract/verifiers/compile.ex` validates the base contract before
   `lib/domain_contract/compiler.ex` calls `UI.compile_props/2` and normalizes it again.
   `lib/domain_contract/ui.ex` adds Phoenix props/slots after that validation. Consider one
   final validation step after all metadata enrichment, with smaller intermediate checks
   only where compilation needs them. Tests should include an invalid selected UI entry and
   unsupported/default-bearing attr types. Keep Phoenix's native declarations as the source.

5. **Use the same offline export path for both export commands.**
   `lib/mix/tasks/domain.contract.ex` calls `Code.ensure_loaded!/1`, while
   `lib/mix/tasks/domain.export.ex` reads BEAM artifacts. Make the single-module command read
   its compiled artifact too. Both commands can share a small file-reader helper and retain
   their output shapes. Check with a module whose `@on_load` fails. Separately, align the
   explanation of `--authority` in `lib/mix/tasks/domain.check.ex` with
   `lib/domain_contract/compatibility.ex`: `check/2` validates authorities but only passes
   candidates to link checking. Clarify the intended role before changing this public behavior.

6. **Extract architecture policy parsing if this subsystem grows.**
   `lib/domain_contract/architecture/checker.ex` combines policy parsing, ownership resolution,
   surface checks and reference diagnostics in 513 lines. The policy parsing/signature helpers
   are a coherent private extraction; keep the diagnostic orchestration together. Existing
   `beam.ex`, `catalog.ex`, `gateway.ex` and `map_access.ex` already have useful boundaries.
   Avoid a generic AST framework or broad generated-code exemptions: the tests rely on exact
   compiler origin, call shape and scope rules.

7. **Deduplicate notification compatibility checks.**
   `lib/domain_contract/compatibility.ex` and `lib/domain_contract/ui.ex` separately find old/new
   notifications and compare their payloads. A private comparison helper could preserve error
   context while sharing the directional type check. Keep UI participant lifecycle and its
   process-local compatibility cache in UI; they have different lifetime from SchemaStore.

## Remaining source coverage and disposition

Paths in this table are relative to `lib/`; files named in the proposals were also reviewed.

| Files | Disposition |
| --- | --- |
| `domain_contract.ex`, `domain_contract/dsl.ex`, `domain_contract/declaration_reference.ex`, `domain_contract/fragment.ex`, `domain_contract/verifiers/compose.ex` | Import changes are confined to declaration options and compile-time composition. Retain Spark integration. |
| `domain_contract/domain.ex`, `domain_contract/entity.ex`, `domain_contract/field.ex`, `domain_contract/operation.ex`, `domain_contract/ui/message.ex` | Small declaration records; no split or abstraction needed. |
| `domain_contract/compiler.ex`, `domain_contract/compiler/spark.ex`, `domain_contract/compiler/boundary.ex`, `domain_contract/verifiers/compile.ex` | Preserve callback isolation. The two small adapter wrappers are clearer than a configurable callback framework. Final metadata validation is proposal 4. |
| `domain_contract/artifact.ex`, `domain_contract/info.ex`, `domain_contract/reference.ex`, `domain_contract/schemas.ex` | Preserve canonical format and scoped validation caching. Apply proposals 1–3 separately. |
| `domain_contract/runtime.ex`, `domain_contract/context.ex`, `domain_contract/schema_store.ex`, `domain_contract/application.ex` | Keep validation, invocation binding and installation-owned lifetime separate. No import work belongs in these runtime modules. |
| `domain_contract/compatibility.ex`, `domain_contract/upgrade.ex` | Preserve directional checks and incremental admission. Avoid folding these into runtime value validation. |
| `domain_contract/implementation.ex`, `domain_contract/owned.ex`, `domain_contract/stub.ex` | Entry coverage, lexical ownership and test dispatch serve distinct purposes. Keep the finite-guard coverage logic and exact BEAM checks. |
| `domain_contract/architecture.ex`, `domain_contract/architecture/beam.ex`, `domain_contract/architecture/catalog.ex`, `domain_contract/architecture/checker.ex`, `domain_contract/architecture/gateway.ex`, `domain_contract/architecture/map_access.ex` | Preserve source review versus compiled enforcement distinction. Proposal 6 is an optional internal extraction. |
| `domain_contract/ui.ex` | Compilation, delivery and prop validation are identifiable sections; at 343 lines no size-only split is needed. Proposals 4 and 7 address actual duplication/boundary issues. |
| `domain_contract/legacy.ex`, `domain_contract/source.ex` | Keep migration and exact-revision materialization outside normal import/runtime paths. No new compatibility format or vendor mechanism. |
| `mix/tasks/domain.check.ex`, `mix/tasks/domain.contract.ex`, `mix/tasks/domain.diff.ex`, `mix/tasks/domain.export.ex`, `mix/tasks/domain.inputs.ex`, `mix/tasks/domain.migrate.ex`, `mix/tasks/domain.vendor.ex` | Small command adapters remain useful. Proposal 5 aligns behavior rather than introducing another CLI layer. |

No SDK, Plugins or other repository files were changed. Git integration/publication belongs
to the development process; the checked workspace is not a newly committed revision.

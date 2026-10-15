# DomainContract

An application-independent Elixir library for owner-local domain declarations,
provider/consumer compatibility checks, and validated call adapters and test stubs.
It does not depend on Midva or SoloKeeper. Domain declarations remain in the owning
application or plugin and are exported from that owner's exact revision.

```elixir
defmodule Chat.Contract do
  use DomainContract

  domain :chat do
    consumes :capability do
      name "tasks"
      version 1

      operation :get do
        input_entity :lookup do
          field :id, :string
        end

        output_entity :summary do
          field :id, :string
          field :status, :string
        end
      end
    end
  end
end
```

`interface` declares a provided surface; `consumes` declares a required surface.
Entities and operations can also be composed from `DomainContract.Fragment` modules.
The compiler validates local schemas and references. Canonical exports without
consumer declarations preserve their original format v1/v2; consumers use format v3.

Run `mix domain.contract Chat.Contract --output chat.json` in the owner project.
Run `mix domain.check tasks.json chat.json` once for the assembled candidate. The
checker rejects missing/ambiguous providers, insufficient cumulative versions,
missing operations, incompatible requests, and responses the consumer cannot handle.
Consumer results are projections: additional provider fields are permitted; request
fields remain closed. Optional fields and optional operation results are significant.

`DomainContract.Port.call/5` validates a consumer's real request and successful result
around an injected transport function. `DomainContract.Stub.dispatcher/2` validates
test handlers against the provider declaration, so a stub cannot silently invent a
different provider API. Error results pass through the existing transport mechanism.
Domain-specific error schemas and behavioral guarantees remain owner responsibilities.

Descriptions specify behavioral obligations. Schema checks do not prove replay,
authorization, ownership, storage durability or Stop behavior; owner vertical tests
and separately run system integration scenarios verify those guarantees.

Library checks: `mix deps.get`, `mix compile --warnings-as-errors`,
`mix format --check-formatted`, and `mix test`.

For private Git dependencies, run `mix domain.vendor` in an authenticated build
checkout before creating a Docker context. This materializes the exact locked Git
revision in `vendor/domain_contract`, excluding credentials and Git metadata.
The application's dependency definition can use that directory in build/source
bundles and its pinned Git dependency in ordinary development checkouts.

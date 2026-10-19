# DomainContract

DomainContract describes public domain interfaces independently of an application,
transport, storage engine or provider registry. One versioned contract can have
multiple implementations. Consumers depend on that contract rather than an
implementation's internal modules.

Contract declarations and their descriptions define the interface and its behavioral
obligations. Canonical exports let independently packaged consumers and implementations
share that definition. Code expresses how an implementation fulfills it; executable
checks establish structural conformance and exercise behavior.

The runtime supplies trusted identity and dispatch. DomainContract validates calls
against the consumer's declared contract. Structural conformance does not prove
business correctness or establish authorization.

- [Declarations](lib/domain_contract.ex), [context](lib/domain_contract/context.ex)
  and [invocation](lib/domain_contract/runtime.ex).
- [Implementation conformance](lib/domain_contract/implementation.ex) and
  [compatibility](lib/domain_contract/compatibility.ex).
- [Executable examples and regression checks](test/) and [project configuration](mix.exs).

defmodule DomainContract do
  @moduledoc """
  Public modules own one inline contract. Consumers name modules and retain their
  compiled requirements. Descriptions are review obligations, not semantic proofs.
  Calls use lexical ownership and a scoped trusted runtime binding when provided.
  """
  use Boundary,
    top_level?: true,
    type: :strict,
    deps:
      [Spark, Jason, Mix] ++
        if(Code.ensure_loaded?(Phoenix.LiveView),
          do: [Phoenix.Component, Phoenix.LiveView],
          else: []
        ),
    exports: [
      Artifact,
      Architecture,
      Compatibility,
      Context,
      {Dsl, []},
      Compiler,
      Fragment,
      Implementation,
      Info,
      Reference,
      Runtime,
      Source,
      Stub,
      UI,
      Owned,
      Domain,
      Entity,
      Field,
      Operation,
      DeclarationReference,
      UI.Message
    ]

  use Spark.Dsl, default_extensions: [extensions: [DomainContract.Dsl]]

  @impl true
  def handle_opts(_options) do
    quote do
      @behaviour DomainContract.Implementation
      require DomainContract
      require DomainContract.UI
      Module.register_attribute(__MODULE__, :domain_contract_definitions, accumulate: true)
      Module.register_attribute(__MODULE__, :domain_contract_calls, accumulate: true)
      @on_definition {DomainContract.Implementation, :on_definition}
      @before_compile DomainContract.Compiler
    end
  end

  @doc "Calls a declared public module using lexical ownership and the current context."
  defmacro call(target, operation, input) do
    owner = DomainContract.Owned.owner(__CALLER__)
    DomainContract.Owned.record(__CALLER__, target, :operations, operation)

    quote do
      DomainContract.Runtime.invoke(
        unquote(owner),
        unquote(target),
        unquote(operation),
        unquote(input),
        DomainContract.Context.current()
      )
    end
  end

  @doc "Explicit trusted-context form for runtimes with captured execution contexts."
  def invoke(context, target, operation, input) do
    with {:ok, binding} <- DomainContract.Context.fetch(context) do
      DomainContract.Runtime.invoke(binding.consumer["module"], target, operation, input, context)
    end
  end

  @doc "Binds a trusted context for this process and restores the previous binding, including on errors."
  def with_context(context, function), do: DomainContract.Context.bind(context, function)
end

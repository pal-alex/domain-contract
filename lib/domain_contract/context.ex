defmodule DomainContract.Context do
  @moduledoc """
  An invocation binding supplied by a trusted runtime adapter.

  `consumer` is a declaration module or immutable canonical export. `caller` is the
  runtime's trusted identity. `dispatch` receives `(name, operation, input, context)`;
  the last argument is the original context, including adapter-owned state.
  A platform context may embed this struct in its `:domain_contract` field.

  This binding is not an authentication mechanism. Never construct it from request
  parameters. Provider selection, availability, authorization, transport, storage
  and durable execution remain responsibilities of the adapter.
  """
  @enforce_keys [:consumer, :caller, :dispatch]
  defstruct [:consumer, :caller, :dispatch, :owner, :scope, :execution_id, schemas: []]

  @type t :: %__MODULE__{
          consumer: module() | map(),
          caller: term(),
          dispatch: (module(), String.t(), term(), term() -> {:ok, term()} | {:error, term()})
        }

  @key {__MODULE__, :binding}
  def current, do: Process.get(@key)

  def bind(context, function) when is_function(function, 0) do
    {:ok, binding} = fetch(context)
    :ok = DomainContract.SchemaStore.pin(self(), binding.schemas)
    :ok = DomainContract.SchemaStore.track(self(), binding.consumer)
    previous = Process.get(@key)
    Process.put(@key, context)

    try do
      function.()
    after
      if is_nil(previous), do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  @doc false
  def fetch(%__MODULE__{consumer: %{"format_version" => 7} = consumer} = context),
    do: {:ok, new(DomainContract.Legacy.convert(consumer), context.caller, context.dispatch)}

  def fetch(%__MODULE__{} = context), do: {:ok, context}
  def fetch(%{domain_contract: %__MODULE__{} = context}), do: fetch(context)
  def fetch(_), do: {:error, {:invalid_contract, :context}}

  @doc "Registers a context before ownership is handed to a worker or service process."
  def lease(context, pid) when is_pid(pid) do
    with {:ok, binding} <- fetch(context),
         :ok <- DomainContract.SchemaStore.pin(pid, binding.schemas),
         do: DomainContract.SchemaStore.track(pid, binding.consumer)
  end

  @doc "Captures a validated consumer snapshot once when the trusted adapter creates a context."
  def new(consumer, caller, dispatch, options \\ [])
      when not is_nil(caller) and is_function(dispatch, 4) do
    source = if is_atom(consumer), do: DomainContract.Info.canonical(consumer), else: consumer
    consumer = DomainContract.Info.canonical(source)

    consumer =
      if Map.has_key?(consumer, "schema"),
        do: DomainContract.Schemas.expand(consumer),
        else: consumer

    case DomainContract.Artifact.validate(consumer) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid consumer contract: #{inspect(reason)}"
    end

    index = DomainContract.Schemas.index([consumer])
    :ok = DomainContract.SchemaStore.retain(Keyword.get(options, :holder, self()), index)

    compact =
      consumer
      |> Map.take(~w(format_version module version consumes subscriptions))
      |> Map.put("schema", DomainContract.Schemas.id(consumer))

    :ok = DomainContract.SchemaStore.track(Keyword.get(options, :holder, self()), compact)

    %__MODULE__{
      consumer: compact,
      caller: caller,
      dispatch: dispatch,
      owner: consumer["module"],
      schemas: Map.keys(index)
    }
  end
end

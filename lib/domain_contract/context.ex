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
    with {:ok, _binding} <- fetch(context) do
      previous = Process.get(@key)
      Process.put(@key, context)

      try do
        function.()
      after
        if is_nil(previous), do: Process.delete(@key), else: Process.put(@key, previous)
      end
    end
  end

  @doc false
  def fetch(%__MODULE__{consumer: %{"format_version" => version}}) when version != 8,
    do: {:error, {:invalid_contract, :format_version}}

  def fetch(%__MODULE__{} = context) do
    if Enum.all?(context.schemas, &DomainContract.SchemaStore.available?/1),
      do: {:ok, context},
      else: {:error, {:invalid_contract, :expired_context}}
  end

  def fetch(%{domain_contract: %__MODULE__{} = context}), do: fetch(context)
  def fetch(_), do: {:error, {:invalid_contract, :context}}

  @doc "Captures a validated consumer without retaining schemas. The trusted installer owns their lifetime."
  def new(consumer, caller, dispatch)
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

    references = (consumer["consumes"] || []) ++ (consumer["subscriptions"] || [])

    compact =
      consumer
      |> Map.take(~w(format_version module version consumes subscriptions))
      |> Map.put("schema", DomainContract.Schemas.id(consumer))

    %__MODULE__{
      consumer: compact,
      caller: caller,
      dispatch: dispatch,
      owner: consumer["module"],
      schemas: references |> Enum.map(& &1["schema"]) |> Enum.uniq()
    }
  end
end

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
  defstruct [:consumer, :caller, :dispatch]

  @type t :: %__MODULE__{
          consumer: module() | map(),
          caller: term(),
          dispatch: (String.t(), String.t(), term(), term() -> {:ok, term()} | {:error, term()})
        }

  @key {__MODULE__, :binding}
  def current, do: Process.get(@key)

  def bind(context, function) when is_function(function, 0) do
    {:ok, _} = fetch(context)
    previous = Process.get(@key)
    Process.put(@key, context)

    try do
      function.()
    after
      if is_nil(previous), do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end

  @doc false
  def fetch(%__MODULE__{} = context), do: {:ok, context}
  def fetch(%{domain_contract: %__MODULE__{} = context}), do: {:ok, context}
  def fetch(_), do: {:error, {:invalid_contract, :context}}

  @doc "Captures a validated consumer snapshot once when the trusted adapter creates a context."
  def new(consumer, caller, dispatch) when not is_nil(caller) and is_function(dispatch, 4) do
    consumer = DomainContract.Info.canonical(consumer)

    case DomainContract.Artifact.validate(consumer) do
      :ok -> %__MODULE__{consumer: consumer, caller: caller, dispatch: dispatch}
      {:error, reason} -> raise ArgumentError, "invalid consumer contract: #{inspect(reason)}"
    end
  end
end

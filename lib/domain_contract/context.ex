defmodule DomainContract.Context do
  @moduledoc """
  An invocation binding supplied by a trusted runtime adapter.

  `consumer` is a declaration module or immutable canonical export. `caller` is the
  runtime's trusted identity. The installed public module owns execution.
  A platform context may embed this struct in its `:domain_contract` field.

  This binding is not an authentication mechanism. Never construct it from request
  parameters. Availability, authorization, transport, storage
  and durable execution remain responsibilities of the adapter.
  """
  @enforce_keys [:consumer, :caller]
  defstruct [:consumer, :caller, schemas: []]

  @type t :: %__MODULE__{
          consumer: module() | map(),
          caller: term()
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
  def new(consumer, caller) when not is_nil(caller) do
    consumer = DomainContract.Info.canonical(consumer)

    consumer =
      if Map.has_key?(consumer, "schema"),
        do: DomainContract.Schemas.expand(consumer),
        else: consumer

    case DomainContract.Artifact.validate(consumer) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid consumer contract: #{inspect(reason)}"
    end

    captured(DomainContract.Info.binding(consumer), caller)
  end

  @doc "Creates a trusted boundary consumer for a selected entry, without deriving nested rights."
  def for_entry(reference, caller) do
    captured(
      %{
        "format_version" => 8,
        "module" => "Elixir.DomainContract.Context",
        "version" => 1,
        "consumes" => [Map.put(reference, "optional", false)]
      },
      caller
    )
  end

  @doc "Binds already checked compact requirements without rebuilding or retaining schemas."
  def captured(consumer, caller) when is_map(consumer) and not is_nil(caller) do
    %__MODULE__{
      consumer: consumer,
      caller: caller,
      schemas:
        ((consumer["consumes"] || []) ++ (consumer["subscriptions"] || []))
        |> Enum.map(& &1["schema"])
        |> Enum.uniq()
    }
  end
end

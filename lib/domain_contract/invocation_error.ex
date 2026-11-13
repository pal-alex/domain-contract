defmodule DomainContract.InvocationError do
  @moduledoc """
  An entry adapter could not deliver an invocation to the operation owner.

  Adapters raise this exception for transport or context failures. Business
  failures use `{:error, reason}` and must satisfy the operation's error schema.
  Runtime turns this exception into `{:error, reason}` at the invocation boundary.
  """
  defexception [:reason]

  @impl true
  def message(%{reason: reason}), do: "contract invocation failed: #{inspect(reason)}"
end

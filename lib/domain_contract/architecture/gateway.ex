defmodule DomainContract.Architecture.Gateway do
  @moduledoc false

  # A reviewed runtime port, scoped to one caller and one expanded expression.
  # These declarations never exempt ordinary static native references.
  def parse(entries) when is_list(entries) do
    with true <- Enum.all?(entries, &valid?/1),
         true <- Enum.uniq_by(entries, &Map.delete(&1, "reason")) == entries do
      {:ok, entries}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  defp valid?(entry) when is_map(entry) do
    Enum.sort(Map.keys(entry)) == ~w(arity dispatch function kind module reason) and
      is_binary(entry["module"]) and String.starts_with?(entry["module"], "Elixir.") and
      is_binary(entry["function"]) and entry["function"] != "" and
      is_integer(entry["arity"]) and entry["arity"] in 0..255 and
      entry["kind"] in ~w(callback native contract) and
      is_binary(entry["dispatch"]) and String.trim(entry["dispatch"]) != "" and
      is_binary(entry["reason"]) and String.trim(entry["reason"]) != ""
  end

  defp valid?(_), do: false

  def matches?(entry, module, %{caller: {name, arity}, dispatch: dispatch} = reference) do
    entry["module"] == Atom.to_string(module) and
      entry["function"] == Atom.to_string(name) and entry["arity"] == arity and
      entry["dispatch"] == dispatch and entry["kind"] == kind(reference)
  end

  def matches?(_, _, _), do: false

  defp kind(%{contract: _}), do: "contract"
  defp kind(%{dynamic: kind}) when kind in [:contract_target, :contract_operation], do: "contract"
  defp kind(%{dynamic: :function}), do: "callback"
  defp kind(%{dynamic: _}), do: "native"
  defp kind(_), do: nil
end

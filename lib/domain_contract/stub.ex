defmodule DomainContract.Stub do
  @moduledoc "Validated runtime dispatcher for domain tests."
  def dispatcher(provider, handlers) do
    contract = DomainContract.Info.canonical(provider)

    fn module, operation, input, _context ->
      with true <- Atom.to_string(module) == contract["module"],
           :ok <- DomainContract.Runtime.input(contract, operation, input),
           {:ok, handler} <- Map.fetch(handlers, operation),
           {:ok, output} <- handler.(input),
           :ok <- DomainContract.Runtime.output(contract, operation, output),
           do: {:ok, output}
    end
  end
end

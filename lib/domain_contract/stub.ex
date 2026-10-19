defmodule DomainContract.Stub do
  @moduledoc "Builds a dispatcher that validates stub requests and successful replies against the provider."
  alias DomainContract.Runtime

  def dispatcher(provider, handlers) do
    names = Enum.map(DomainContract.Compatibility.provided(provider), & &1["name"])

    fn name, operation, input, _context ->
      with true <- name in names,
           :ok <- Runtime.input(provider, name, operation, input),
           {:ok, handler} <- Map.fetch(handlers, {name, operation}),
           {:ok, output} <- handler.(input),
           :ok <- Runtime.output(provider, name, operation, output) do
        {:ok, output}
      else
        false -> {:error, :invalid_interface}
        :error -> {:error, :not_stubbed}
        {:error, _} = error -> error
      end
    end
  end
end

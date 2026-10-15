defmodule DomainContract.Stub do
  @moduledoc "Builds a dispatcher that validates stub requests and successful replies against the provider."
  alias DomainContract.Runtime

  def dispatcher(provider, handlers) do
    contract = DomainContract.Info.contract(provider)
    names = Enum.map(contract.interfaces, & &1.name)

    fn name, operation, input ->
      with true <- name in names,
           :ok <- Runtime.input(provider, operation, input),
           {:ok, handler} <- Map.fetch(handlers, {name, operation}),
           {:ok, output} <- handler.(input),
           :ok <- Runtime.output(provider, operation, output) do
        {:ok, output}
      else
        false -> {:error, :invalid_interface}
        :error -> {:error, :not_stubbed}
        {:error, _} = error -> error
      end
    end
  end
end

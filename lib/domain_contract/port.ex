defmodule DomainContract.Port do
  @moduledoc "Validates real consumer calls against their declared requirements."
  alias DomainContract.Runtime

  def call(consumer, {_kind, name} = interface, operation, input, dispatch) do
    with :ok <- Runtime.consumer_input(consumer, interface, operation, input),
         {:ok, output} <- dispatch.(name, operation, input),
         :ok <- Runtime.consumer_output(consumer, interface, operation, output) do
      {:ok, output}
    end
  end
end

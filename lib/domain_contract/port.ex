defmodule DomainContract.Port do
  @moduledoc false
  alias DomainContract.{Context, Runtime}

  def call(context, name, operation, input) when is_binary(name) and is_binary(operation) do
    with {:ok, binding} <- Context.fetch(context),
         :ok <- valid_binding(binding),
         {:ok, reference} <- Runtime.dependency(binding.consumer, name),
         :ok <- Runtime.reference_input(reference, operation, input) do
      case binding.dispatch.(name, operation, input, context) do
        {:ok, output} ->
          with :ok <- Runtime.reference_output(reference, operation, output), do: {:ok, output}

        {:error, _} = error ->
          error

        _ ->
          {:error, {:invalid_contract, :invalid_result}}
      end
    end
  end

  def call(_, _, _, _), do: {:error, {:invalid_contract, :invocation}}

  defp valid_binding(%{caller: caller, dispatch: dispatch})
       when not is_nil(caller) and is_function(dispatch, 4),
       do: :ok

  defp valid_binding(_), do: {:error, {:invalid_contract, :context}}
end

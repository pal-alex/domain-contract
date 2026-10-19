defmodule DomainContract.Verifiers.Compile do
  @moduledoc false
  alias DomainContract.Verifiers.Compose
  alias DomainContract.Verifiers.Validate
  use Spark.Dsl.Transformer

  # Spark's after-verify errors are warnings. Fail during compilation so invalid
  # contracts cannot be shipped by a build that does not use --warnings-as-errors.
  @impl true
  def transform(dsl) do
    with {:ok, dsl} <- Compose.transform(dsl),
         {:ok, dsl} <- DomainContract.Verifiers.References.transform(dsl),
         :ok <- Validate.verify(dsl) do
      {:ok, dsl}
    end
  end
end

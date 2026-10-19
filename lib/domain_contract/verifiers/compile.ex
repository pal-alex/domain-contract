defmodule DomainContract.Verifiers.Compile do
  @moduledoc false
  alias DomainContract.Verifiers.Compose
  alias DomainContract.Verifiers.Validate
  alias DomainContract.Info
  use Spark.Dsl.Transformer

  # Spark's after-verify errors are warnings. Fail during compilation so invalid
  # contracts cannot be shipped by a build that does not use --warnings-as-errors.
  @impl true
  def transform(dsl) do
    with {:ok, dsl} <- Compose.transform(dsl),
         {:ok, dsl} <- DomainContract.Verifiers.References.transform(dsl),
         :ok <- Validate.verify(dsl) do
      {:ok, persist_artifact(dsl)}
    end
  end

  defp persist_artifact(dsl) do
    case Spark.Dsl.Transformer.get_entities(dsl, [:contract]) do
      [domain] ->
        artifact = domain |> Info.contract() |> Info.canonical()

        Spark.Dsl.Transformer.eval(
          dsl,
          [],
          quote do
            Module.register_attribute(__MODULE__, :domain_contract_artifact, persist: true)
            @domain_contract_artifact unquote(Macro.escape(artifact))
          end
        )

      [] ->
        dsl
    end
  end
end

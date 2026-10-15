defmodule DomainContract.Fragment do
  @moduledoc """
  A Spark declaration module composed into a domain through `types Module` or
  `operations Module`. Put named entities or operations inside `declarations do`.

  References are resolved and verified in the complete domain, so fragments can
  refer to shared entities declared in other modules. Spark source annotations
  remain attached to the original declarations.
  """

  defmacro __using__(_opts) do
    quote do
      use Spark.Dsl.Fragment, of: DomainContract
    end
  end
end

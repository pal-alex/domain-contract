defmodule DomainContract.Fragment do
  @moduledoc """
  A Spark type declaration module composed through `types Module`. Put named
  entities inside `declarations do`. Operations are declared only by their owner.

  References are resolved and verified in the complete domain, so fragments can
  refer to shared entities declared in other modules. Spark source annotations
  remain attached to the original declarations.

  `types(Module, only: [:name])` selects roots and their transitive dependencies
  across the complete composition. Unreachable declarations are omitted. Use
  `require Module` before a selected import when compiling both modules in the
  same build. `only: []` contributes declarations for other roots without adding
  roots of its own. Reachable duplicate names and unresolved references fail.
  """

  defmacro __using__(_opts) do
    quote do
      use Spark.Dsl.Fragment, of: DomainContract
    end
  end
end

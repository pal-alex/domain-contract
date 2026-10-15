defmodule DomainContract.Interface do
  @moduledoc false
  defstruct [:kind, :name, :version, :description, operations: [], __spark_metadata__: nil]
end

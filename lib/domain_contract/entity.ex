defmodule DomainContract.Entity do
  @moduledoc false
  defstruct [:name, :description, keys: :atoms, fields: [], __spark_metadata__: nil]
end

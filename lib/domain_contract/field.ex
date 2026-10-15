defmodule DomainContract.Field do
  @moduledoc false
  defstruct [:name, :type, :description, optional: false, __spark_metadata__: nil]
end

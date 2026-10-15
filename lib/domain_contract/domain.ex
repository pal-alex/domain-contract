defmodule DomainContract.Domain do
  @moduledoc false
  defstruct [
    :name,
    :description,
    interfaces: [],
    consumes: [],
    entities: [],
    __spark_metadata__: nil
  ]
end

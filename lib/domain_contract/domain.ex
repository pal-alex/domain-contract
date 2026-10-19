defmodule DomainContract.Domain do
  @moduledoc false
  defstruct [
    :name,
    :description,
    interfaces: [],
    implements: [],
    consumes: [],
    entities: [],
    __spark_metadata__: nil
  ]
end

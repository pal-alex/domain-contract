defmodule DomainContract.UI.Message do
  @moduledoc false
  defstruct [
    :module,
    :name,
    :description,
    :definition,
    kind: :command,
    payload: %{},
    __spark_metadata__: nil
  ]
end

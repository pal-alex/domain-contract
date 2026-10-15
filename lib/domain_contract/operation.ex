defmodule DomainContract.Operation do
  @moduledoc false
  defstruct [
    :name,
    :input,
    :output,
    :description,
    inputs: [],
    outputs: [],
    optional_output: false,
    __spark_metadata__: nil
  ]
end

defmodule DomainContract.Operation do
  @moduledoc false
  defstruct [
    :name,
    :input,
    :output,
    :input_type,
    :output_type,
    :description,
    error_type: :never,
    inputs: [],
    outputs: [],
    optional_output: false,
    __spark_metadata__: nil
  ]
end

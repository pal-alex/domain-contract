defmodule DomainContract.Domain do
  @moduledoc false
  defstruct [
    :module,
    :version,
    :responsibility,
    :description,
    kind: :domain,
    metadata: %{},
    operations: [],
    consumes: [],
    subscriptions: [],
    entities: [],
    commands: [],
    notifications: [],
    props: [],
    slots: [],
    __spark_metadata__: nil
  ]
end

defmodule DomainContract.Application do
  @moduledoc false
  use Boundary, top_level?: true, deps: [DomainContract]
  use Application

  @impl true
  def start(_type, _options) do
    Supervisor.start_link([DomainContract.SchemaStore],
      strategy: :one_for_one,
      name: DomainContract.Supervisor
    )
  end
end

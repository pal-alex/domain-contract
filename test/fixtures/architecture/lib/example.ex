defmodule ArchitectureExample.Inventory.Record do
  defstruct [:id]
end

defmodule ArchitectureExample.Inventory.Helper do
  def fetch(id), do: %ArchitectureExample.Inventory.Record{id: id}
end

defmodule ArchitectureExample.Inventory do
  use DomainContract

  contract do
    version(1)
    responsibility("Owns inventory and its private records.")
    operation(:fetch, input_type: :integer, output_type: :integer)
  end

  @impl true
  def call("fetch", id, _context) do
    record = ArchitectureExample.Inventory.Helper.fetch(id)
    {:ok, Map.fetch!(record, :id)}
  end
end

defmodule ArchitectureExample.Checkout do
  use DomainContract
  alias ArchitectureExample.Inventory, as: Stock

  contract do
    version(1)
    responsibility("Owns checkout.")
    operation(:run, input_type: :integer, output_type: :integer)
    consumes(Stock, only: [:fetch])
  end

  @impl true
  def call("run", id, _context), do: DomainContract.call(Stock, :fetch, id)
end

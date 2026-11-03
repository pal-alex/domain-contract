defmodule ArchitectureExample.Inventory.Record do
  defstruct [:id]
end

defmodule ArchitectureExample.Inventory.Helper do
  def fetch(id), do: %ArchitectureExample.Inventory.Record{id: id}
  def secret, do: :private
end

defmodule ArchitectureExample.Inventory do
  use DomainContract

  contract do
    version(1)
    responsibility("Owns inventory and its records.")

    metadata(%{
      architecture: %{
        native: [fetch: 1],
        exports: %{
          ArchitectureExample.Inventory.Record => [__struct__: 0, __struct__: 1]
        }
      }
    })
  end

  def fetch(id), do: ArchitectureExample.Inventory.Helper.fetch(id)
end

defmodule ArchitectureExample.Checkout do
  use DomainContract
  alias ArchitectureExample.Inventory, as: Stock

  contract do
    version(1)
    responsibility("Owns checkout.")
    metadata(%{architecture: %{uses: [Stock], native: [run: 1]}})
  end

  def run(id), do: Stock.fetch(id)
end

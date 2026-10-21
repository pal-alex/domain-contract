defmodule Mix.Tasks.Domain.Migrate do
  @shortdoc "Converts format 7 JSON metadata to a format 8 bundle; does not load executable packages"
  use Boundary, classify_to: DomainContract
  use Mix.Task

  @impl true
  def run([input, output]) do
    owners =
      input
      |> File.read!()
      |> Jason.decode!()
      |> List.wrap()
      |> Enum.map(&DomainContract.Legacy.convert/1)

    File.write!(output, owners |> DomainContract.Schemas.bundle() |> DomainContract.Info.encode())
  end

  def run(_), do: Mix.raise("usage: mix domain.migrate format7.json format8.json")
end

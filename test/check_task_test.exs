defmodule DomainContract.CheckTaskTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "contract checks do not start the product application", %{tmp_dir: root} do
    library = Path.expand("..", __DIR__)
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule ContractProbe.MixProject do
      use Mix.Project
      def project, do: [app: :contract_probe, version: "0.1.0",
        deps: [{:domain_contract, path: #{inspect(library)}}]]
      def application, do: [mod: {ContractProbe, []}]
    end
    """)

    File.write!(Path.join(root, "lib/contract_probe.ex"), """
    defmodule ContractProbe do
      use Application
      def start(_, _), do: raise("Contract checking must not start the product")
    end
    """)

    File.cp!(Path.join(library, "mix.lock"), Path.join(root, "mix.lock"))
    File.write!(Path.join(root, "contracts.json"), "[]")

    options = [
      cd: root,
      env: [{"MIX_ENV", "dev"}, {"ERL_FLAGS", "+S 2:2"}],
      stderr_to_stdout: true
    ]

    {installed, status} = System.cmd("mix", ["deps.get", "--check-locked"], options)
    assert status == 0, installed
    {output, status} = System.cmd("mix", ["domain.check", "contracts.json"], options)
    assert status == 0, output
    assert output =~ "Domain contracts are compatible"
  end
end

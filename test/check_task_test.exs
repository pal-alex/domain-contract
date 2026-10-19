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

    authority = %{
      "format_version" => 1,
      "domain" => "public",
      "description" => nil,
      "entities" => [],
      "interfaces" => [
        %{
          "kind" => "capability",
          "name" => "probe",
          "version" => 1,
          "description" => nil,
          "operations" => []
        }
      ]
    }

    consumer = %{
      "format_version" => 4,
      "domain" => "consumer",
      "description" => nil,
      "interfaces" => [],
      "entities" => [],
      "implements" => [],
      "consumes" => [
        %{
          "kind" => "capability",
          "name" => "probe",
          "version" => 1,
          "optional" => false,
          "definition" => DomainContract.Reference.resolve(authority, "probe", 1)
        }
      ]
    }

    File.write!(Path.join(root, "authority.json"), Jason.encode!(authority))
    File.write!(Path.join(root, "contracts.json"), Jason.encode!([consumer]))

    {output, status} =
      System.cmd(
        "mix",
        ["domain.check", "--authority", "authority.json", "contracts.json"],
        options
      )

    assert status != 0, output
    assert output =~ "missing_provider"
    refute output =~ "unknown_contract"

    File.write!(Path.join(root, "contracts.json"), Jason.encode!([authority, consumer]))
    File.write!(Path.join(root, "second-authority.json"), "[]")

    {output, status} =
      System.cmd(
        "mix",
        [
          "domain.check",
          "--authority",
          "authority.json",
          "--authority",
          "second-authority.json",
          "contracts.json"
        ],
        options
      )

    assert status == 0, output
  end

  @tag :tmp_dir
  test "independent packages enforce private boundaries and cannot call the internal legacy port",
       %{tmp_dir: root} do
    library = Path.expand("..", __DIR__)
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule BoundaryProbe.MixProject do
      use Mix.Project
      def project, do: [app: :boundary_probe, version: "0.1.0",
        compilers: [:boundary] ++ Mix.compilers(),
        deps: [{:boundary, "~> 0.11", runtime: false}, {:spark, "~> 2.7.3"},
          {:domain_contract, path: #{inspect(library)}}]]
    end
    """)

    File.cp!(Path.join(library, "mix.lock"), Path.join(root, "mix.lock"))

    options = [
      cd: root,
      env: [{"MIX_ENV", "dev"}, {"ERL_FLAGS", "+S 2:2"}],
      stderr_to_stdout: true
    ]

    {output, status} = System.cmd("mix", ["deps.get", "--check-locked"], options)
    assert status == 0, output
    source = Path.join(root, "lib/probe.ex")

    File.write!(source, """
    defmodule ForeignDomain do
      use Boundary, exports: []
    end
    defmodule ForeignDomain.Private do
      def hidden, do: :private
    end
    defmodule BoundaryProbe do
      use Boundary, deps: [DomainContract, ForeignDomain]
      def private_call, do: ForeignDomain.Private.hidden()
      def legacy_call(context), do: DomainContract.Port.call(context, "tasks", "get", %{})
    end
    """)

    {output, status} = System.cmd("mix", ["compile", "--warnings-as-errors"], options)
    assert status != 0, output
    assert output =~ "ForeignDomain.Private"
    assert output =~ "DomainContract.Port"
    assert output =~ "not exported"

    File.write!(source, """
    defmodule BoundaryProbe do
      use Boundary, deps: [DomainContract, Spark], exports: [Contract]
      def call(context), do: DomainContract.call(context, "tasks", "get", %{})
    end
    defmodule BoundaryProbe.Contract do
      use DomainContract
      domain :boundary_probe do
        interface :capability do
          name "probe"
          version 1
          operation :read do
            input_entity :input do
            end
            output_entity :output do
            end
          end
        end
      end
    end
    """)

    {output, status} = System.cmd("mix", ["clean"], options)
    assert status == 0, output
    {output, status} = System.cmd("mix", ["compile", "--warnings-as-errors"], options)
    assert status == 0, output
  end
end

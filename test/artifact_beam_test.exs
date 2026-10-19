defmodule DomainContract.ArtifactBeamTest do
  use ExUnit.Case, async: true
  alias DomainContract.{Artifact, Implementation, Info}

  @tag :tmp_dir
  test "compiled exports retain composed schemas and references without activating code", %{
    tmp_dir: directory
  } do
    namespace = namespace()
    marker = Path.join(directory, "owner-loaded")

    beams =
      compile("""
      defmodule #{namespace}.Types do
        use DomainContract.Fragment
        declarations do
          entity :value do
            description "A complete owner-defined value."
            field :id, :string, description: "The stable identifier."
          end
        end
      end
      defmodule #{namespace}.Owner do
        use DomainContract
        @on_load :activate
        def activate, do: File.write!(#{inspect(marker)}, "activated")
        domain :original do
          description "Keep the original domain obligations."
          types #{namespace}.Types
          interface :api do
            name "new.interface"
            version 3
            operation :read do
              description "Return every owned value unchanged."
              input_type :null
              output_type {:list, {:open_entity, :value}}
            end
          end
        end
      end
      defmodule #{namespace}.Declaration do
        use DomainContract
        domain :consumer do
          implements "new.interface", version: 3, contract: #{namespace}.Owner
          consumes "new.interface", version: 3, contract: #{namespace}.Owner, optional: true
        end
      end
      defmodule #{namespace}.Provider do
        use DomainContract.Implementation, contract: #{namespace}.Declaration
        def call(operation, _, _) when operation in @contract_operations, do: {:ok, []}
      end
      """)

    owner = Module.concat(namespace, Owner)
    declaration = Module.concat(namespace, Declaration)
    provider = Module.concat(namespace, Provider)
    types = Module.concat(namespace, Types)
    expected = Info.canonical(owner)
    expected_declaration = Info.canonical(declaration)

    assert expected["format_version"] == 5
    assert expected["description"] == "Keep the original domain obligations."
    assert File.exists?(marker)
    File.rm!(marker)
    Enum.each(Map.keys(beams), &unload/1)

    assert {:ok, ^expected} = Artifact.from_beam(beams[owner])
    assert {:ok, ^expected_declaration} = Artifact.from_beam(beams[declaration])
    assert {:error, :not_contract} = Artifact.from_beam(beams[types])
    assert {:error, :not_contract} = Artifact.from_beam(beams[provider])
    assert :ok = Implementation.check_beam(beams[provider], [expected_declaration])
    refute File.exists?(marker)
    assert Enum.all?(Map.keys(beams), &(:code.is_loaded(&1) == false))
  end

  test "ordinary BEAM modules do not claim a declaration export" do
    module = Module.concat(namespace(), Ordinary)
    beams = compile("defmodule #{inspect(module)} do\ndef call, do: :ok\nend")
    unload(module)
    assert {:error, :not_contract} = Artifact.from_beam(beams[module])
    assert :code.is_loaded(module) == false
  end

  test "malformed exports and missing declaration functions fail without loading code" do
    for {artifact, functions} <- [
          {:invalid, ""},
          {%{"interfaces" => nil}, "def entities(_), do: []; def spark_dsl_config, do: %{}"},
          {%{
             "format_version" => 1,
             "domain" => "unverified",
             "description" => nil,
             "interfaces" => [],
             "entities" => []
           }, ""}
        ] do
      module = Module.concat(namespace(), Malformed)

      beams =
        compile("""
        defmodule #{inspect(module)} do
          Module.register_attribute(__MODULE__, :domain_contract_artifact, persist: true)
          @domain_contract_artifact #{inspect(artifact)}
          #{functions}
        end
        """)

      unload(module)
      assert {:error, :invalid_artifact} = Artifact.from_beam(beams[module])
      assert :code.is_loaded(module) == false
    end
  end

  test "invalid BEAM input is distinct from an ordinary non-contract module" do
    for input <- ["invalid beam", <<>>, nil, ~c"not-a-beam-file"],
        do: assert({:error, :invalid_beam} = Artifact.from_beam(input))
  end

  defp namespace,
    do: Module.concat(__MODULE__, "Probe#{System.unique_integer([:positive])}")

  defp compile(source) do
    beams = Code.compile_string(source)
    on_exit(fn -> Enum.each(beams, fn {module, _} -> unload(module) end) end)
    Map.new(beams)
  end

  defp unload(module) do
    :code.delete(module)
    :code.purge(module)
  end
end

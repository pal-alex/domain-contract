defmodule DomainContract.RootTypesTest do
  use ExUnit.Case, async: false

  alias DomainContract.{
    Artifact,
    Compatibility,
    Context,
    Implementation,
    Info,
    Reference,
    Runtime
  }

  defmodule Public do
    use DomainContract

    domain :tools do
      entity :empty do
      end

      entity :rate do
        field(:model, :string)
        field(:price, :float)
      end

      entity :unused do
        field(:value, :integer)
      end

      interface :tools do
        name("development.tools")
        version(1)
        operation(:head, input: :empty, output_type: :string)
        operation(:paths, input: :empty, output_type: {:list, :string})
        operation(:clean, input: :empty, output_type: :null)
        operation(:pricing, input: :empty, output_type: {:list, {:entity, :rate}})
        operation(:echo, input_type: :string, output_type: :string)
        operation(:nullable, input: :empty, output_type: {:list, :string}, optional_output: true)
      end
    end
  end

  defmodule Consumer do
    use DomainContract

    domain :consumer do
      consumes("development.tools", version: 1, contract: Public)
    end
  end

  defmodule Provider do
    use Implementation, contract: Public
    def call("head", _, _), do: {:ok, "sha"}
    def call("paths", _, _), do: {:ok, ["lib", "test"]}
    def call("clean", _, _), do: {:ok, nil}
    def call("pricing", _, _), do: {:ok, [%{"model" => "one", "price" => 1.5}]}
    def call("echo", input, _), do: {:ok, input}
    def call("nullable", _, _), do: {:ok, nil}
  end

  test "typed roots preserve scalar, list and nil business results through the canonical call" do
    assert :ok = Artifact.validate(Public)
    assert :ok = Compatibility.check([Public, Consumer])
    assert :ok = Implementation.check(Provider)

    context =
      Context.new(Consumer, "trusted", fn _, op, input, outer ->
        Provider.call(op, input, outer)
      end)

    for {operation, input, expected} <- [
          {"head", %{}, "sha"},
          {"paths", %{}, ["lib", "test"]},
          {"clean", %{}, nil},
          {"pricing", %{}, [%{"model" => "one", "price" => 1.5}]},
          {"echo", "unchanged", "unchanged"},
          {"nullable", %{}, nil}
        ] do
      assert {:ok, ^expected} =
               DomainContract.call(context, "development.tools", operation, input)
    end
  end

  test "root and nested element validation rejects incorrect values before and after dispatch" do
    context = Context.new(Consumer, "trusted", fn _, _, _, _ -> send(self(), :dispatched) end)
    assert {:error, _} = DomainContract.call(context, "development.tools", "echo", %{})
    refute_received :dispatched

    for {operation, output} <- [
          {"head", %{"sha" => "sha"}},
          {"head", nil},
          {"clean", %{}},
          {"paths", ["valid", 1]},
          {"pricing", [%{"model" => "one", "price" => "invalid"}]},
          {"pricing", [%{"model" => "one", "price" => 1.0, "extra" => true}]}
        ] do
      context = Context.new(Consumer, "trusted", fn _, _, _, _ -> {:ok, output} end)
      assert {:error, _} = DomainContract.call(context, "development.tools", operation, %{})
    end

    assert :ok = Runtime.output(Public, "paths", [])
    assert :ok = Runtime.output(Public, "clean", nil)
    assert :ok = Runtime.output(Public, "nullable", nil)
    assert {:error, _} = Runtime.output(Public, "nullable", [7])
  end

  test "format five gates typed roots and snapshots contain exactly the reachable entities" do
    for source <- [Public, Consumer] do
      assert Info.contract(source).format_version == 5
      artifact = source |> Info.json() |> Jason.decode!()
      assert :ok = Artifact.validate(artifact)

      assert {:error, :invalid_artifact} =
               Artifact.validate(Map.put(artifact, "format_version", 4))
    end

    snapshot = Reference.resolve(Public, "development.tools", 1)
    assert Enum.map(snapshot["entities"], & &1["name"]) == ["empty", "rate"]
    assert Reference.valid?(snapshot)

    artifact = Info.canonical(Public)
    [operation | _] = artifact["interfaces"] |> hd() |> Map.fetch!("operations")
    assert operation["output_type"] == "null"

    for change <- [
          &Map.put(&1, "output_type", "invented"),
          &Map.put(&1, "output", "empty"),
          &Map.put(&1, "output_type", ["list", ["entity", "absent"]])
        ] do
      broken =
        update_in(artifact, ["interfaces", Access.at(0), "operations", Access.at(0)], change)

      assert {:error, :invalid_artifact} = Artifact.validate(broken)
    end

    changed =
      update_in(
        artifact,
        ["interfaces", Access.at(0), "operations", Access.at(0)],
        &Map.put(&1, "output_type", "string")
      )

    refute Reference.resolve(changed, "development.tools", 1)["digest"] == snapshot["digest"]
    assert {:error, errors} = Compatibility.check([changed, Consumer], [Public])
    assert Enum.any?(errors, &(&1.reason == :conflicting_contract))
  end

  @tag :tmp_dir
  test "independent declarations and offline BEAM checks preserve typed root snapshots", %{
    tmp_dir: root
  } do
    path = Path.join(root, "tools.json")
    File.write!(path, Info.json(Public))
    declaration = Module.concat(__MODULE__, "Independent#{System.unique_integer([:positive])}")
    provider = Module.concat(declaration, Provider)

    Code.compile_string("""
    defmodule #{inspect(declaration)} do
      use DomainContract
      domain :replacement do
        implements "development.tools", version: 1, contract: #{inspect(path)}
      end
    end
    """)

    [{^provider, beam}] =
      Code.compile_string("""
      defmodule #{inspect(provider)} do
        use DomainContract.Implementation, contract: #{inspect(declaration)}
        def call(operation, input, context) when operation in @contract_operations do
          #{inspect(Provider)}.call(operation, input, context)
        end
      end
      """)

    assert :ok = Compatibility.check([declaration, Consumer], [Public])
    :code.delete(provider)
    :code.purge(provider)
    assert :ok = Implementation.check_beam(beam, [Info.canonical(declaration)])
    assert :code.is_loaded(provider) == false
    assert Info.contract(declaration).format_version == 5
  end

  test "invalid root declarations fail compilation instead of falling back to an entity or opaque schema" do
    for properties <- [
          "input: :empty, output: :empty, output_type: :string",
          "input: :empty, output_type: {:list, {:entity, :absent}}",
          "input: :empty, output_type: :invented",
          "input_type: {:dictionary, :unknown}, output_type: :null"
        ] do
      module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use DomainContract
          domain :bad do
            entity :empty do
            end
            interface :api do
              name "bad"
              version 1
              operation :get, #{properties}
            end
          end
        end
        """)
      end
    end
  end
end

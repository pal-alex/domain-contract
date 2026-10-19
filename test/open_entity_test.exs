defmodule DomainContract.OpenEntityTest do
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

    domain :catalog do
      description(
        "Descriptors have typed stable fields and opaque owner-defined extension values."
      )

      entity :empty do
      end

      entity :settings do
        field(:enabled, :boolean)
      end

      entity :descriptor do
        field(:id, :string)
        field(:version, :string)
        field(:provides, {:dictionary, :integer})
        field(:settings, {:entity, :settings}, optional: true)
      end

      entity :unused do
        field(:ignored, :string)
      end

      interface :api do
        name("catalog")
        version(1)
        operation(:list, input: :empty, output_type: {:list, {:open_entity, :descriptor}})
      end
    end
  end

  defmodule Consumer do
    use DomainContract

    domain :consumer do
      consumes("catalog", version: 1, contract: Public)
    end
  end

  defp descriptor,
    do: %{"id" => "custom", "version" => "1.0.0", "provides" => %{"custom" => 1}}

  test "explicit extensibility preserves the original flat list and owner extension values" do
    value =
      descriptor()
      |> Map.put("settings", %{"enabled" => true})
      |> Map.put("owner_extension", %{"nested" => [1, true, nil]})
      |> Map.put("private_owner_value", {:opaque, make_ref()})

    context = Context.new(Consumer, "trusted", fn "catalog", "list", %{}, _ -> {:ok, [value]} end)
    assert {:ok, [^value]} = DomainContract.call(context, "catalog", "list", %{})
    assert :ok = Runtime.output(Public, "list", [])

    # Openness applies only at the explicitly marked entity use.
    assert {:error, {:invalid_contract, _}} =
             DomainContract.call(context, "catalog", "list", %{"extra" => true})

    closed =
      update_in(
        Info.canonical(Public),
        ["interfaces", Access.at(0), "operations", Access.at(0), "output_type"],
        fn _ -> ["list", ["entity", "descriptor"]] end
      )

    assert :ok = Runtime.output(closed, "list", [descriptor()])
    assert {:error, {:invalid_contract, _}} = Runtime.output(closed, "list", [value])
  end

  test "known fields, closed nested entities and string keys remain enforced" do
    for value <- [
          Map.delete(descriptor(), "id"),
          Map.put(descriptor(), "id", nil),
          Map.put(descriptor(), "version", 7),
          Map.put(descriptor(), "provides", %{"custom" => "1"}),
          Map.put(descriptor(), "settings", %{"enabled" => "true"}),
          Map.put(descriptor(), "settings", %{"enabled" => true, "extra" => true}),
          Map.put(descriptor(), :atom_extension, "not a public string key"),
          "not a descriptor"
        ] do
      assert {:error, {:invalid_contract, _}} = Runtime.output(Public, "list", [value])
    end

    assert :ok = Runtime.output(Public, "list", [Map.put(descriptor(), "settings", nil)])
    assert {:error, _} = Runtime.output(Public, "list", %{"plugins" => [descriptor()]})
  end

  test "open entity references are reachable, immutable and explicitly format five" do
    for source <- [Public, Consumer] do
      assert Info.contract(source).format_version == 5
      assert :ok = Artifact.validate(source)

      assert {:error, :invalid_artifact} =
               source |> Info.canonical() |> Map.put("format_version", 4) |> Artifact.validate()
    end

    snapshot = Reference.resolve(Public, "catalog", 1)
    assert Enum.map(snapshot["entities"], & &1["name"]) == ["descriptor", "empty", "settings"]
    assert Reference.valid?(snapshot)

    closed =
      put_in(
        Info.canonical(Public),
        ["interfaces", Access.at(0), "operations", Access.at(0), "output_type"],
        ["list", ["entity", "descriptor"]]
      )

    refute Reference.resolve(closed, "catalog", 1)["digest"] == snapshot["digest"]
    assert {:error, errors} = Compatibility.check([closed, Consumer], [Public])
    assert Enum.any?(errors, &(&1.reason == :conflicting_contract))

    unknown =
      put_in(
        Info.canonical(Public),
        ["interfaces", Access.at(0), "operations", Access.at(0), "output_type"],
        ["list", ["open_entity", "absent"]]
      )

    assert {:error, :invalid_artifact} = Artifact.validate(unknown)
  end

  test "nested open entity fields select format five without a typed operation root" do
    module = Module.concat(__MODULE__, "Nested#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use DomainContract
      domain :nested do
        entity :item do
          field :id, :string
        end
        entity :batch do
          field :items, {:dictionary, {:open_entity, :item}}
        end
        interface :api do
          name "batch"
          version 1
          operation :echo, input: :batch, output: :batch
        end
      end
    end
    """)

    assert Info.contract(module).format_version == 5
    assert :ok = Artifact.validate(module)

    assert :ok =
             Runtime.output(module, "echo", %{"items" => %{"one" => %{"id" => "one", "x" => 1}}})

    assert {:error, _} = Runtime.output(module, "echo", %{"items" => %{"one" => %{"x" => 1}}})
    assert Reference.valid?(Reference.resolve(module, "batch", 1))
  end

  @tag :tmp_dir
  test "independent replacements retain open entity schemas in offline BEAM conformance", %{
    tmp_dir: root
  } do
    path = Path.join(root, "catalog.json")
    File.write!(path, Info.json(Public))
    declaration = Module.concat(__MODULE__, "Replacement#{System.unique_integer([:positive])}")
    provider = Module.concat(declaration, Provider)

    Code.compile_string("""
    defmodule #{inspect(declaration)} do
      use DomainContract
      domain :replacement do
        implements "catalog", version: 1, contract: #{inspect(path)}
      end
    end
    """)

    [{^provider, beam}] =
      Code.compile_string("""
      defmodule #{inspect(provider)} do
        use DomainContract.Implementation, contract: #{inspect(declaration)}
        def call(operation, _, _) when operation in @contract_operations, do: {:ok, []}
      end
      """)

    assert :ok = Compatibility.check([declaration, Consumer], [Public])
    :code.delete(provider)
    :code.purge(provider)
    assert :ok = Implementation.check_beam(beam, [Info.canonical(declaration)])
    assert :code.is_loaded(provider) == false
  end

  test "unknown open entity names and unsupported extension syntax fail compilation" do
    for type <- [
          "{:open_entity, :absent}",
          "{:open_entity, 7}",
          "{:open_entity, :empty, :opaque}"
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
              operation :read, input: :empty, output_type: #{type}
            end
          end
        end
        """)
      end
    end
  end
end

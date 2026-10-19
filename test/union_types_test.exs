defmodule DomainContract.UnionTypesTest do
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

    domain :cursor do
      entity :cursor do
        field(:file, :integer)
        field(:line, :integer)
      end

      entity :request do
        field(:cursor, {:union, [{:enum, [0]}, {:entity, :cursor}]})
      end

      entity :unused do
        field(:unrelated, :string)
      end

      interface :api do
        name("cursor")
        version(1)

        operation(:echo,
          input: :request,
          output_type: {:union, [{:enum, [0]}, {:entity, :cursor}]}
        )

        operation(:root,
          input_type: {:union, [{:entity, :cursor}, {:enum, [0]}]},
          output_type: {:union, [{:entity, :cursor}, {:enum, [0]}]}
        )

        operation(:page,
          input_type: :null,
          output_type: {:union, [:null, {:list, {:entity, :cursor}}]}
        )

        operation(:zero, input_type: {:enum, [0]}, output_type: {:enum, [0]})
      end
    end
  end

  defmodule Consumer do
    use DomainContract

    domain :reader do
      consumes("cursor", version: 1, contract: Public)
    end
  end

  defmodule EnumOnly do
    use DomainContract

    domain :scalar_choice do
      entity :value do
        field(:zero, {:enum, [0]})
      end

      interface :api do
        name("scalar.choice")
        version(1)
        operation(:echo, input: :value, output: :value)
      end
    end
  end

  defmodule Provider do
    use Implementation, contract: Public
    def call("echo", input, _), do: {:ok, input["cursor"]}
    def call("root", input, _), do: {:ok, input}
    def call("zero", input, _), do: {:ok, input}
    def call("page", _, _), do: {:ok, nil}
  end

  test "canonical calls preserve an exact zero sentinel or closed cursor without envelopes" do
    context =
      Context.new(Consumer, "trusted", fn _, op, input, outer ->
        Provider.call(op, input, outer)
      end)

    for value <- [0, %{"file" => 2, "line" => 10}] do
      assert {:ok, ^value} = DomainContract.call(context, "cursor", "echo", %{"cursor" => value})
      assert {:ok, ^value} = DomainContract.call(context, "cursor", "root", value)
    end

    assert {:ok, nil} = DomainContract.call(context, "cursor", "page", nil)
    assert {:ok, 0} = DomainContract.call(context, "cursor", "zero", 0)
    assert :ok = Runtime.output(Public, "page", [%{"file" => 0, "line" => 0}])
    assert {:error, _} = Runtime.output(Public, "page", [%{"file" => 0, "line" => "bad"}])
  end

  test "every alternative remains strict before dispatch and on successful results" do
    context = Context.new(Consumer, "trusted", fn _, _, _, _ -> send(self(), :dispatched) end)

    for value <- [
          1,
          0.0,
          "0",
          true,
          nil,
          [],
          %{"file" => 0},
          %{"file" => "0", "line" => 0},
          %{"file" => 0, "line" => 0, "extra" => true}
        ] do
      assert {:error, {:invalid_contract, _}} =
               DomainContract.call(context, "cursor", "echo", %{"cursor" => value})

      refute_received :dispatched
    end

    assert {:error, _} = Runtime.input(Public, "zero", 0.0)

    for value <- [1, "0", %{"file" => 0, "line" => "bad"}] do
      context = Context.new(Consumer, "trusted", fn _, _, _, _ -> {:ok, value} end)

      assert {:error, {:invalid_contract, _}} =
               DomainContract.call(context, "cursor", "echo", %{"cursor" => 0})
    end

    context = Context.new(Consumer, "trusted", fn _, _, _, _ -> {:error, :not_ready} end)
    assert {:error, :not_ready} = DomainContract.call(context, "cursor", "root", 0)
  end

  test "format six gates owners and references, preserving reachable union branches" do
    for source <- [Public, Consumer] do
      artifact = Info.canonical(source)
      assert artifact["format_version"] == 6
      assert :ok = Artifact.validate(artifact)

      for old <- [1, 2, 4, 5],
          do:
            assert(
              {:error, :invalid_artifact} =
                Artifact.validate(Map.put(artifact, "format_version", old))
            )
    end

    definition = Reference.resolve(Public, "cursor", 1)
    assert Enum.map(definition["entities"], & &1["name"]) == ["cursor", "request"]
    assert Reference.valid?(definition)

    artifact = Info.canonical(Public)

    for type <- [
          ["union", []],
          ["union", ["integer"]],
          ["union", ["integer", ["entity", "missing"]]],
          ["enum", [%{}]],
          ["enum", [0, 0]]
        ] do
      changed = put_in(artifact, ["entities", Access.at(1), "fields", Access.at(0), "type"], type)
      assert {:error, :invalid_artifact} = Artifact.validate(changed)
    end
  end

  test "non-string enums alone require format six without typed roots or union fields" do
    artifact = Info.canonical(EnumOnly)
    assert artifact["format_version"] == 6
    assert :ok = Artifact.validate(artifact)
    assert :ok = Runtime.input(EnumOnly, "echo", %{"zero" => 0})
    assert {:error, _} = Runtime.input(EnumOnly, "echo", %{"zero" => 0.0})
    assert {:error, :invalid_artifact} = Artifact.validate(Map.put(artifact, "format_version", 2))
  end

  @tag :tmp_dir
  test "independent references and offline BEAM conformance retain union schemas", %{
    tmp_dir: directory
  } do
    path = Path.join(directory, "cursor.json")
    File.write!(path, Info.json(Public))
    declaration = Module.concat(__MODULE__, "Replacement#{System.unique_integer([:positive])}")
    provider = Module.concat(declaration, Provider)

    beams =
      Code.compile_string("""
      defmodule #{inspect(declaration)} do
        use DomainContract
        domain :replacement do
          implements "cursor", version: 1, contract: #{inspect(path)}
        end
      end
      defmodule #{inspect(provider)} do
        use DomainContract.Implementation, contract: #{inspect(declaration)}
        def call(operation, input, context) when operation in @contract_operations do
          #{inspect(Provider)}.call(operation, input, context)
        end
      end
      """)
      |> Map.new()

    expected = Info.canonical(declaration)
    assert expected["format_version"] == 6
    assert :ok = Compatibility.check([declaration, Consumer], [Public])
    for module <- Map.keys(beams), do: unload(module)
    assert {:ok, ^expected} = Artifact.from_beam(beams[declaration])
    assert :ok = Implementation.check_beam(beams[provider], [expected])
    assert Enum.all?(Map.keys(beams), &(:code.is_loaded(&1) == false))

    changed =
      put_in(Info.canonical(Public), ["entities", Access.at(1), "fields", Access.at(0), "type"], [
        "union",
        [["enum", [0, 1]], ["entity", "cursor"]]
      ])

    assert {:error, reasons} = Compatibility.check([changed], [Public])
    assert Enum.any?(reasons, &(&1.reason == :conflicting_contract))
  end

  test "alternative and scalar enum order do not alter canonical identity" do
    modules =
      for {values, alternatives} <- [
            {"[1.0, 1, true, false, nil, \"named\"]", ":integer, :null"},
            {"[nil, false, \"named\", 1, true, 1.0]", ":null, :integer"}
          ] do
        module = Module.concat(__MODULE__, "Ordered#{System.unique_integer([:positive])}")

        Code.compile_string("""
        defmodule #{inspect(module)} do
          use DomainContract
          domain :ordering do
            entity :request do
              field :value, {:enum, #{values}}
              field :nested, {:dictionary, {:variant, %{"cursor" => {:union, [#{alternatives}]}}}}
            end
            interface :api do
              name "ordering"
              version 1
              operation :echo, input: :request, output: :request
            end
          end
        end
        """)

        module
      end

    [one, two] = Enum.map(modules, &Info.canonical/1)
    assert one == two
    assert one["format_version"] == 6

    for value <- [1, 1.0, true, false, nil, "named"] do
      assert :ok =
               Runtime.input(hd(modules), "echo", %{
                 "value" => value,
                 "nested" => %{
                   "begin" => %{"type" => "cursor", "data" => nil},
                   "page" => %{"type" => "cursor", "data" => 3}
                 }
               })
    end

    assert {:error, _} =
             Runtime.input(hd(modules), "echo", %{
               "value" => 1,
               "nested" => %{"page" => %{"type" => "cursor", "data" => "bad"}}
             })
  end

  test "malformed alternatives and scalar enums fail compilation" do
    for type <- [
          "{:union, []}",
          "{:union, [:integer]}",
          "{:union, [:integer, :unknown]}",
          "{:union, [:null, {:entity, :missing}]}",
          "{:enum, [0, 0]}",
          "{:enum, [%{}]}",
          "{:enum, [\"\"]}"
        ] do
      module = Module.concat(__MODULE__, "Invalid#{System.unique_integer([:positive])}")

      assert_raise Spark.Error.DslError, fn ->
        Code.compile_string("""
        defmodule #{inspect(module)} do
          use DomainContract
          domain :invalid do
            interface :api do
              name "invalid"
              version 1
              operation :echo, input_type: #{type}, output_type: :null
            end
          end
        end
        """)
      end
    end
  end

  defp unload(module) do
    :code.delete(module)
    :code.purge(module)
  end
end

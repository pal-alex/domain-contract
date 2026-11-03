defmodule DomainContract.TypeImportTest do
  use ExUnit.Case, async: false
  alias DomainContract.{Artifact, Info, Runtime, Schemas}

  @moduletag :tmp_dir

  defmodule Types do
    use DomainContract.Fragment

    declarations do
      entity :task do
        description("Task description")
        field(:project, {:entity, :project}, description: "Project reference")
        field(:children, {:list, {:entity, :task}}, optional: true)
      end

      entity :project do
        field(:id, :integer)
      end

      entity :unused do
        field(:value, :string)
      end
    end
  end

  defmodule CrossReferences do
    use DomainContract.Fragment

    declarations do
      entity :root do
        field(:external, {:entity, :project})
      end

      entity :unused do
        field(:invalid, {:entity, :not_composed})
      end
    end
  end

  defmodule Operations do
    use DomainContract.Fragment

    declarations do
      operation(:echo, input: :task, output: :task)
    end
  end

  setup do
    previous = Application.get_env(:domain_contract, :metadata_paths, [])
    Application.put_env(:domain_contract, :metadata_paths, [])
    on_exit(fn -> Application.put_env(:domain_contract, :metadata_paths, previous) end)
    :ok
  end

  test "legacy fragments and operation fragments still compose" do
    {module, _} =
      consumer(
        """
        types #{inspect(Types)}
        operations #{inspect(Operations)}
        """,
        ~s|def call("echo", input, _), do: {:ok, input}|
      )

    assert names(module) == ~w(project task unused)
    assert Runtime.input(module, :echo, %{project: %{id: 1}}) == :ok
  end

  test "selection retains transitive and cyclic dependencies and descriptions" do
    {module, _} = consumer("types(#{inspect(Types)}, only: [:task])")
    assert names(module) == ~w(project task)
    task = Enum.find(module.__contract__()["entities"], &(&1["name"] == "task"))
    assert task["description"] == "Task description"
    assert hd(task["fields"])["description"] == "Project reference"
    assert :ok = Artifact.validate(module)
  end

  test "cross-fragment references resolve before pruning, regardless of order" do
    imports = [
      "types(#{inspect(CrossReferences)}, only: [:root])",
      "types(#{inspect(Types)}, only: [])"
    ]

    for lines <- [imports, Enum.reverse(imports)] do
      {module, _} = consumer(Enum.join(lines, "\n"))
      assert names(module) == ~w(project root)
      assert :ok = Artifact.validate(module)
    end

    assert_raise Spark.Error.DslError, ~r/root.*references missing entity "project"/, fn ->
      consumer(hd(imports))
    end
  end

  test "roots must belong to their source and selected names cannot collide" do
    assert_raise Spark.Error.DslError, ~r/unknown entity "project".*CrossReferences/, fn ->
      consumer("""
      types(#{inspect(CrossReferences)}, only: [:project])
      types #{inspect(Types)}
      """)
    end

    for {extra, name} <- [
          {"entity :project", "project"},
          {"types(#{inspect(Types)}, only: [:project])", "task"}
        ] do
      assert_raise Spark.Error.DslError, ~r/entity name collision for "#{name}"/, fn ->
        consumer("types(#{inspect(Types)}, only: [:task])\n" <> extra)
      end
    end
  end

  test "invalid only and mixed fragments fail clearly" do
    assert_raise Spark.Error.DslError, ~r/only/, fn ->
      consumer("types(#{inspect(Types)}, only: :task)")
    end

    assert_raise Spark.Error.DslError, ~r/must declare only entities/, fn ->
      consumer("types(#{inspect(Operations)}, only: [:echo])")
    end
  end

  test "every type constructor contributes dependencies, while enum values are data" do
    fragment = unique("Containers")

    Code.compile_string("""
    defmodule #{inspect(fragment)} do
      use DomainContract.Fragment
      declarations do
        entity :root do
          field :list, {:list, {:entity, :list_item}}
          field :dictionary, {:dictionary, {:entity, :dictionary_item}}
          field :nullable, {:nullable, {:entity, :nullable_item}}
          field :union, {:union, [:null, {:entity, :union_item}]}
          field :variant, {:variant, %{item: {:entity, :variant_item}}}
          field :object, %{nested: {:entity, :object_item}}
          field :open, {:open_entity, :open_item}
          field :enum, {:enum, [["entity", "not_a_reference"]]}
        end
        entity :list_item do
          field :next, {:entity, :transitive}
        end
        entity :transitive do
          field :back, {:nullable, {:entity, :root}}
        end
        entity :dictionary_item
        entity :nullable_item
        entity :union_item
        entity :variant_item
        entity :object_item
        entity :open_item
        entity :unused
      end
    end
    """)

    {module, _} = consumer("types(#{inspect(fragment)}, only: [:root])")

    assert names(module) ==
             ~w(dictionary_item list_item nullable_item object_item open_item root transitive union_item variant_item)

    assert Artifact.validate(module) == :ok
  end

  test "explicit require orders selected fragment compilation across source files", ctx do
    fragment = unique("ParallelFragment")
    owner = unique("ParallelConsumer")
    fragment_path = Path.join(ctx.tmp_dir, "fragment.ex")
    consumer_path = Path.join(ctx.tmp_dir, "consumer.ex")

    File.write!(fragment_path, """
    defmodule #{inspect(fragment)} do
      use DomainContract.Fragment
      declarations do
        entity :selected
        entity :unused
      end
    end
    """)

    source = consumer_source(owner, "types(#{inspect(fragment)}, only: [:selected])", "")

    File.write!(
      consumer_path,
      String.replace(
        source,
        "use DomainContract",
        "require #{inspect(fragment)}\nuse DomainContract"
      )
    )

    assert {:ok, modules, []} = Kernel.ParallelCompiler.compile([consumer_path, fragment_path])
    assert owner in modules
    assert names(owner) == ["selected"]
  end

  test "owner metadata preserves canonical entities and validation without operation permissions",
       ctx do
    {owner, beam, artifact} = owner(ctx)
    path = Path.join(ctx.tmp_dir, "owner.json")
    File.write!(path, Info.encode(Schemas.bundle([artifact])))
    Application.put_env(:domain_contract, :metadata_paths, [path])
    unload(owner)

    {module, consumer_beam} = consumer("types(#{inspect(owner)}, only: [:task])")
    imported = module.__contract__()
    assert imported["format_version"] == 8
    assert imported["entities"] == Enum.reject(artifact["entities"], &(&1["name"] == "unused"))
    assert imported["consumes"] == []
    assert imported["schemas"] == %{}
    assert imported["operations"] == []
    assert :code.is_loaded(owner) == false
    refute File.exists?(Path.join(ctx.tmp_dir, "provider-loaded"))
    assert {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(consumer_beam, [:imports])
    refute Enum.any?(imports, &(elem(&1, 0) == owner))

    valid = %{
      required: "yes",
      nullable: nil,
      project: %{id: 1},
      open: %{"id" => 2, "extra" => true},
      status: :ready,
      variant: %{"type" => "project", "data" => %{id: 3}},
      nested: %{projects: [%{id: 4}]},
      dictionary: %{"x" => %{id: 5}},
      union: %{id: 6}
    }

    invalid = [
      Map.delete(valid, :required),
      Map.put(valid, :required, nil),
      Map.put(valid, :optional, nil),
      Map.put(valid, :nullable, 1),
      Map.put(valid, :project, %{id: 1, extra: true}),
      Map.put(valid, :status, "ready"),
      Map.put(valid, :status, :missing),
      Map.put(valid, :variant, %{"type" => "missing", "data" => %{id: 3}}),
      Map.put(valid, :dictionary, %{"x" => %{id: "bad"}}),
      Map.put(valid, :nested, %{projects: [%{id: "bad"}]}),
      Map.put(valid, :union, true)
    ]

    for value <- [valid | invalid] do
      expected = Runtime.validate_type({:entity, :task}, value, artifact["entities"])
      assert Runtime.validate_type({:entity, :task}, value, imported["entities"]) == expected
      if value == valid, do: assert(expected == :ok), else: assert(match?({:error, _}, expected))
    end

    # Explicit BEAM metadata uses the same selection without loading its owner.
    beam_path = Path.join(ctx.tmp_dir, "owner.beam")
    File.write!(beam_path, beam)
    Application.put_env(:domain_contract, :metadata_paths, [beam_path])
    {from_beam, _} = consumer("types(#{inspect(owner)}, only: [:task])")
    assert from_beam.__contract__()["entities"] == imported["entities"]
    assert :code.is_loaded(owner) == false
    refute File.exists?(Path.join(ctx.tmp_dir, "provider-loaded"))

    assert_raise CompileError, ~r/undeclared dependency/, fn ->
      consumer(
        "types(#{inspect(owner)}, only: [:task])",
        "def run, do: DomainContract.call(#{inspect(owner)}, :get, %{})"
      )
    end
  end

  test "missing, ambiguous and unknown owner inputs fail without loading provider code", ctx do
    {owner, beam, artifact} = owner(ctx)
    # A loaded owner is not a substitute for explicit/compiled metadata.
    assert_raise ArgumentError, ~r/missing contract metadata/, fn ->
      DomainContract.Reference.resolve_metadata(owner)
    end

    unload(owner)

    assert_raise RuntimeError, ~r/missing contract metadata/, fn ->
      consumer("types(#{inspect(owner)}, only: [:task])")
    end

    paths =
      for version <- [1, 2] do
        path = Path.join(ctx.tmp_dir, "owner-#{version}.json")

        File.write!(
          path,
          Info.encode([artifact |> Map.delete("digest") |> Map.put("version", version)])
        )

        path
      end

    Application.put_env(:domain_contract, :metadata_paths, paths)

    assert_raise RuntimeError, ~r/ambiguous contract metadata/, fn ->
      consumer("types(#{inspect(owner)}, only: [:task])")
    end

    Application.put_env(:domain_contract, :metadata_paths, [hd(paths)])

    assert_raise Spark.Error.DslError, ~r/unknown entity "missing"/, fn ->
      consumer("types(#{inspect(owner)}, only: [:missing])")
    end

    Application.put_env(:domain_contract, :metadata_paths, [])
    beam_path = Path.join(ctx.tmp_dir, "#{owner}.beam")
    File.write!(beam_path, beam)
    Code.prepend_path(ctx.tmp_dir)
    on_exit(fn -> Code.delete_path(ctx.tmp_dir) end)
    {module, _} = consumer("types(#{inspect(owner)}, only: [:task])")
    assert names(module) == ~w(project task)
    assert :code.is_loaded(owner) == false
    refute File.exists?(Path.join(ctx.tmp_dir, "provider-loaded"))
  end

  test "invalid owner metadata and owner/local name collisions fail at compilation", ctx do
    {owner, _, artifact} = owner(ctx)
    path = Path.join(ctx.tmp_dir, "owner.json")
    Application.put_env(:domain_contract, :metadata_paths, [path])
    File.write!(path, Info.encode(Map.put(artifact, "digest", "invalid")))

    assert_raise RuntimeError, ~r/invalid contract/, fn ->
      consumer("types(#{inspect(owner)}, only: [:task])")
    end

    File.write!(path, Info.encode(artifact))

    assert_raise Spark.Error.DslError, ~r/entity name collision for "project"/, fn ->
      consumer("types(#{inspect(owner)}, only: [:task])\nentity :project")
    end
  end

  test "fresh VM builds and validates a consumer from JSON with no provider implementation",
       ctx do
    {owner, _, artifact} = owner(ctx)
    path = Path.join(ctx.tmp_dir, "metadata.json")
    File.write!(path, Info.encode([artifact]))
    script = Path.join(ctx.tmp_dir, "build.exs")

    File.write!(script, """
    Application.ensure_all_started(:domain_contract)
    Application.put_env(:domain_contract, :metadata_paths, [#{inspect(path)}])
    :non_existing = :code.which(#{inspect(owner)})
    [{consumer, beam}] = Code.compile_string(#{inspect(consumer_source("IndependentConsumer", "types(#{inspect(owner)}, only: [:task])", ""))})
    {:ok, artifact} = DomainContract.Artifact.from_beam(beam)
    [] = artifact["consumes"]
    ["project", "task"] = Enum.map(artifact["entities"], & &1["name"])
    :ok = DomainContract.Runtime.validate_type({:entity, :project}, %{id: 1}, artifact["entities"])
    {:error, _} = DomainContract.Runtime.validate_type({:entity, :project}, %{id: nil}, artifact["entities"])
    false = :code.is_loaded(#{inspect(owner)})
    File.write!(#{inspect(Path.join(ctx.tmp_dir, "consumer.beam"))}, beam)
    IO.puts("built " <> inspect(consumer))
    """)

    args = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)]) ++ [script]

    {output, status} =
      System.cmd("elixir", args, stderr_to_stdout: true, env: [{"ERL_FLAGS", "+S 2:2"}])

    assert status == 0, output
    assert output =~ "built IndependentConsumer"
    assert {:ok, _} = Artifact.from_beam(File.read!(Path.join(ctx.tmp_dir, "consumer.beam")))
  end

  defp owner(ctx) do
    module = unique("Owner")
    marker = Path.join(ctx.tmp_dir, "provider-loaded")
    # This callback makes accidental loading visible, including without call/3.
    [{^module, beam}] =
      Code.compile_string(
        consumer_source(
          module,
          """
            entity :project do
          description "Canonical project"
              field :id, :integer, description: "Stable ID"
            end
            entity :task do
          description "Canonical task"
              field :required, :string
              field :optional, :integer, optional: true, description: "May be omitted"
              field :nullable, {:nullable, :string}
              field :project, {:entity, :project}
              field :open, {:open_entity, :project}
              field :status, {:enum, [:ready, "closed"]}
              field :variant, {:variant, %{project: {:entity, :project}, text: :string}}
              field :nested, %{projects: {:list, {:entity, :project}}}
              field :dictionary, {:dictionary, {:entity, :project}}
              field :union, {:union, [:null, {:entity, :project}]}
            end
            entity :unused do
              field :value, :string
            end
            operation :get, input_type: :map, output: :task
          """,
          """
            @on_load :loaded
            def loaded, do: File.write!(#{inspect(marker)}, "loaded")
            def call("get", _, _), do: raise("provider executed")
          """
        )
      )

    assert {:ok, artifact} = Artifact.from_beam(beam)
    File.rm!(marker)
    {module, beam, artifact}
  end

  defp consumer(contract, implementation \\ "") do
    module = unique("Consumer")
    [{^module, beam}] = Code.compile_string(consumer_source(module, contract, implementation))
    {module, beam}
  end

  defp consumer_source(module, contract, implementation),
    do: """
    defmodule #{inspect_module(module)} do
      use DomainContract
      contract do
        version 1
        responsibility "Owns test values."
        #{contract}
      end
      #{implementation}
    end
    """

  defp inspect_module(module) when is_atom(module), do: inspect(module)
  defp inspect_module(module), do: module
  defp unique(prefix), do: Module.concat(["#{prefix}#{System.unique_integer([:positive])}"])
  defp names(module), do: Enum.map(module.__contract__()["entities"], & &1["name"])

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
  end
end

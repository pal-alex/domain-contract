defmodule DomainContract.SchemaLifecycleTest do
  use ExUnit.Case, async: false
  alias DomainContract.Artifact
  alias DomainContract.Context
  alias DomainContract.Info
  alias DomainContract.Reference
  alias DomainContract.Schemas
  alias DomainContract.SchemaStore
  alias DomainContract.Upgrade

  defmodule Owner do
    use DomainContract

    contract do
      version(1)
      responsibility("Owns a shared interface for admission and lifecycle tests.")
      operation(:echo, input_type: %{description: :string}, output_type: :string)
    end

    def call("echo", input, _), do: {:ok, input[:description] || input["description"]}
  end

  defmodule Consumer do
    use DomainContract

    contract do
      version(1)
      responsibility("Calls the selected shared interface.")
      consumes(Owner)
    end

    def local_echo(value), do: DomainContract.call(Owner, :echo, %{description: value})
  end

  defmodule RootConsumer do
    use DomainContract

    contract do
      version(1)
      responsibility("Composes a consumer without copying its transitive schema graph.")
      consumes(Consumer)
    end
  end

  test "nested ownership has the same canonical metadata before and after export or transfer" do
    root = Info.canonical(RootConsumer)
    assert Map.keys(root["schemas"]) == [Schemas.id(Info.canonical(Consumer))]
    assert [root] == root |> List.wrap() |> Schemas.bundle() |> Schemas.unbundle()
    payload = %{"contracts" => [root]}
    assert payload == payload |> Schemas.pack() |> Schemas.unpack_prepared()
    assert Artifact.validate(root) == :ok
  end

  defmodule SelfConsumer do
    use DomainContract

    contract do
      version(1)
      responsibility("Owns a plain local self-dependency.")
      operation(:echo, input_type: :string, output_type: :string)
      consumes(__MODULE__)
    end

    def call("echo", value, _), do: {:ok, value}
    def local_echo(value), do: DomainContract.call(__MODULE__, :echo, value)
  end

  defmodule OptionalOwner do
    use DomainContract

    contract do
      version(1)
      responsibility("Owns an optional plain local interface.")
      operation(:echo, input_type: :string, output_type: :string)
    end

    def call("echo", value, _), do: {:ok, value}
  end

  defmodule OptionalConsumer do
    use DomainContract

    contract do
      version(1)
      responsibility("Calls an optional local owner using independent requirements.")
      consumes(OptionalOwner, optional: true)
    end

    def echo(value), do: DomainContract.call(OptionalOwner, :echo, value)
  end

  setup do
    :ok =
      SchemaStore.replace(
        self(),
        Schemas.index(Enum.map([Owner, Consumer, SelfConsumer], &Info.canonical/1))
      )

    :ok
  end

  test "a plain optional dependency can be absent without losing its captured schema" do
    :code.soft_purge(OptionalOwner)
    :code.delete(OptionalOwner)
    :code.soft_purge(OptionalOwner)
    assert {:error, {:unavailable, OptionalOwner}} = OptionalConsumer.echo("ok")
    assert {:error, {:invalid_contract, _}} = OptionalConsumer.echo(42)
  end

  test "1, 10 and 50 consumers have compact references to one shared revision" do
    owner = Info.canonical(Owner)

    for count <- [1, 10, 50] do
      consumers =
        for n <- 1..count do
          Consumer
          |> Info.canonical()
          |> Map.delete("digest")
          |> Map.put("module", "Elixir.SharedConsumer#{n}")
        end

      bundle = Schemas.bundle([owner | consumers])
      shared = Schemas.id(owner)
      assert Enum.count(bundle["schemas"], fn {id, _} -> id == shared end) == 1
      refs = Enum.flat_map(bundle["contracts"], &(&1["consumes"] || []))
      assert length(refs) == count
      assert Enum.all?(refs, &(&1["schema"] == shared and not Map.has_key?(&1, "definition")))
      assert Enum.all?(Schemas.unbundle(bundle), &(Artifact.validate(&1) == :ok))
      :ok = SchemaStore.retain(self(), Schemas.index(consumers))
      contexts = Enum.map(consumers, &Context.new(&1, :trusted))
      assert Enum.all?(contexts, &(:erlang.external_size(&1) < 1500))
      assert :ok = DomainContract.Runtime.reference_input(hd(refs), :echo, %{description: "kept"})
      assert {:error, _} = DomainContract.Runtime.reference_input(hd(refs), :echo, %{})
    end
  end

  test "incremental admission checks the changed provider and its incoming edges" do
    owner = Info.canonical(Owner)
    caller = Info.canonical(Consumer)

    unrelated =
      caller
      |> Map.delete("digest")
      |> Map.put("module", "Elixir.Unrelated")
      |> Map.put("consumes", [])

    replacement = owner |> Map.delete("digest") |> Map.put("description", "New documentation")

    assert {:ok, change} =
             Upgrade.prepare([owner, caller, unrelated], [replacement, caller, unrelated])

    assert MapSet.new(change.affected) == MapSet.new([owner["module"], caller["module"]])
    broken = replacement |> Map.put("operations", [])

    assert {:error, [%{module: module, reason: %{reason: :removed}}]} =
             Upgrade.prepare([owner, caller], [broken, caller])

    assert module == owner["module"]
  end

  test "an obsolete context cannot veto a new selected composition" do
    owner = Info.canonical(Owner)
    caller = Info.canonical(Consumer)
    binding = Context.new(caller, :trusted)

    changed =
      caller
      |> Map.delete("digest")
      |> Map.put("version", 2)
      |> Map.put("consumes", [])
      |> Map.put("schemas", %{})

    broken = owner |> Map.delete("digest") |> Map.put("operations", [])
    assert {:ok, update} = Upgrade.prepare([owner, caller], [broken, changed])
    :ok = SchemaStore.replace(self(), update.schemas)

    assert {:error, {:invalid_contract, :expired_context}} =
             DomainContract.invoke(binding, Owner, :echo, %{description: "ok"})
  end

  test "an existing scope calls new compatible provider code after hot reload" do
    module = Module.concat(__MODULE__, HotProvider)

    source = fn version ->
      "defmodule #{inspect(module)} do use DomainContract; contract do version #{version}; responsibility \"Owns a hot replacement test.\"; operation :echo, input_type: :string, output_type: :string end; def call(\"echo\", input, _), do: {:ok, \"v#{version}:\" <> input} end"
    end

    Code.compile_string(source.(1))
    owner = Info.canonical(module)

    caller =
      Consumer
      |> Info.canonical()
      |> Map.delete("digest")
      |> Map.put("consumes", [Map.put(Schemas.reference(owner), "optional", false)])
      |> Map.put("schemas", Schemas.index([owner]))

    :ok = SchemaStore.replace(self(), Schemas.index([owner, caller]))

    binding =
      Context.new(caller, :trusted)

    try do
      Context.bind(binding, fn ->
        assert {:ok, "v1:ok"} = DomainContract.invoke(binding, module, :echo, "ok")
        :code.soft_purge(module)
        Code.compiler_options(ignore_module_conflict: true)
        Code.compile_string(source.(2))
        replacement = Info.canonical(module)
        assert {:ok, update} = Upgrade.prepare([owner, caller], [replacement, caller])
        :ok = SchemaStore.replace(self(), update.schemas)

        assert :ok =
                 SchemaStore.approve(hd(caller["consumes"])["schema"], Schemas.id(replacement))

        assert Context.current() == binding
        assert {:ok, "v2:ok"} = DomainContract.invoke(binding, module, :echo, "ok")
      end)
    after
      Code.compiler_options(ignore_module_conflict: false)
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
    end
  end

  test "updating a consumer does not widen an older context's declared dependencies" do
    owner = Info.canonical(Owner)
    caller = Info.canonical(Consumer)
    binding = Context.new(caller, :trusted)
    other = SelfConsumer |> Info.canonical() |> Map.delete("digest") |> Map.put("consumes", [])

    updated =
      caller
      |> Map.delete("digest")
      |> Map.update!("consumes", &(&1 ++ [Map.put(Schemas.reference(other), "optional", false)]))
      |> Map.update!("schemas", &Map.merge(&1, Schemas.index([other])))

    assert {:ok, update} = Upgrade.prepare([owner, caller], [owner, updated, other])
    :ok = SchemaStore.replace(self(), update.schemas)

    assert {:error, {:invalid_contract, :undeclared_dependency}} =
             DomainContract.invoke(binding, SelfConsumer, :echo, "ok")
  end

  test "schema reference mismatch and tampered build inputs are rejected" do
    owner = Info.canonical(Consumer)
    [ref] = owner["consumes"]

    assert {:error, :invalid_artifact} =
             Artifact.validate(
               owner
               |> Map.delete("digest")
               |> put_in(["consumes"], [Map.put(ref, "schema", "missing")])
             )

    assert_raise ArgumentError, fn ->
      Reference.definition(Map.put(ref, "module", "Elixir.Foreign"), owner)
    end
  end

  test "nested scopes only bind contexts and restore the parent after exceptions" do
    outer = Context.new(Consumer, :outer)
    inner = Context.new(Consumer, :inner)
    baseline = SchemaStore.stats()

    Context.bind(outer, fn ->
      assert Context.current() == outer

      assert_raise RuntimeError, "scoped failure", fn ->
        Context.bind(inner, fn ->
          assert Context.current() == inner
          raise "scoped failure"
        end)
      end

      assert Context.current() == outer
    end)

    assert Context.current() == nil
    assert SchemaStore.stats() == baseline
  end

  test "plain local calls validate inline schemas without runtime registration or hashing" do
    tracked = [{SchemaStore, :retain, 2}, {Schemas, :index, 1}, {Reference, :digest, 1}]
    Enum.each(tracked, &:erlang.trace_pattern(&1, true, [:local, :call_count]))

    try do
      for _ <- 1..100 do
        assert {:ok, "ok"} = Consumer.local_echo("ok")
        assert {:ok, "ok"} = SelfConsumer.local_echo("ok")
      end

      assert {:error, {:invalid_contract, _}} = Consumer.local_echo(42)
      assert {:error, {:invalid_contract, _}} = SelfConsumer.local_echo(42)
      for mfa <- tracked, do: assert({:call_count, 0} == :erlang.trace_info(mfa, :call_count))
    after
      Enum.each(tracked, &:erlang.trace_pattern(&1, false, [:local, :call_count]))
    end
  end

  test "a task uses a captured context without registering a lease" do
    binding = Context.new(Consumer, :trusted)
    baseline = SchemaStore.stats()

    task =
      Task.async(fn ->
        assert Context.current() == nil
        Context.bind(binding, fn -> Consumer.local_echo("ok") end)
      end)

    assert {:ok, "ok"} = Task.await(task)
    assert SchemaStore.stats() == baseline
  end

  test "runtime bindings reject old metadata instead of converting it into current rights" do
    binding = Context.new(Consumer, :trusted)
    legacy = %{binding | consumer: Map.put(binding.consumer, "format_version", 7)}
    assert {:error, {:invalid_contract, :format_version}} = Context.fetch(legacy)

    assert {:error, {:invalid_contract, :format_version}} =
             DomainContract.invoke(legacy, Owner, :echo, %{description: "ok"})

    assert {:error, {:invalid_contract, :format_version}} =
             DomainContract.Runtime.dependency(legacy.consumer, Owner)
  end

  test "invocation uses installation schemas without registering or hashing on each call" do
    binding = Context.new(Consumer, :trusted)
    tracked = [{SchemaStore, :retain, 2}, {SchemaStore, :replace, 2}, {Reference, :digest, 1}]
    Enum.each(tracked, &:erlang.trace_pattern(&1, true, [:local, :call_count]))

    try do
      for _ <- 1..100 do
        assert {:ok, "ok"} = DomainContract.invoke(binding, Owner, :echo, %{description: "ok"})
      end

      for mfa <- tracked, do: assert({:call_count, 0} == :erlang.trace_info(mfa, :call_count))
    after
      Enum.each(tracked, &:erlang.trace_pattern(&1, false, [:local, :call_count]))
    end
  end

  test "creating and binding contexts never retain a removed installation" do
    baseline = SchemaStore.stats()
    owner = Info.canonical(Consumer) |> Map.delete("digest") |> Map.put("version", 101)
    :ok = SchemaStore.replace(self(), Schemas.index([owner]))
    binding = Context.new(owner, :trusted)

    Context.bind(binding, fn ->
      :ok = SchemaStore.release(self())

      assert {:error, {:invalid_contract, :expired_context}} =
               DomainContract.invoke(binding, Owner, :echo, %{description: "ok"})
    end)

    assert {:error, {:invalid_contract, :expired_context}} =
             Context.bind(binding, fn -> flunk("expired scope") end)

    assert SchemaStore.stats().holders == baseline.holders - 1
  end

  test "installation tuple holders remain monitored after their PID holder is released" do
    owner = Info.canonical(Owner) |> Map.delete("digest") |> Map.put("version", 200)
    id = Schemas.id(owner)
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        :ok = SchemaStore.retain(self(), Schemas.index([owner]))
        :ok = SchemaStore.replace({self(), :installation}, Schemas.index([owner]))
        :ok = SchemaStore.release(self())
        send(parent, :tuple_held)
        receive do: (:finish -> :ok)
      end)

    assert_receive :tuple_held
    assert SchemaStore.available?(id)
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    _ = SchemaStore.stats()
    refute SchemaStore.available?(id)
  end

  test "admission of a removed schema returns an error instead of recreating a stale link" do
    owner = Info.canonical(Owner) |> Map.delete("digest") |> Map.put("version", 301)
    replacement = Map.put(owner, "version", 302)
    holder = {self(), :candidate}
    :ok = SchemaStore.replace(holder, Schemas.index([owner, replacement]))
    required = Schemas.id(owner)
    offered = Schemas.id(replacement)
    :ok = SchemaStore.release(holder)

    assert {:error, {:invalid_contract, :expired_context}} =
             SchemaStore.approve(required, offered)

    refute SchemaStore.approved?(required, offered)
  end

  test "rollback is checked against consumers which already require a new operation" do
    original = Info.canonical(Owner)
    added = hd(original["operations"]) |> Map.put("name", "lookup")
    replacement = original |> Map.delete("digest") |> Map.update!("operations", &(&1 ++ [added]))
    reference = Reference.requirement(replacement)
    consumer = Consumer |> Info.canonical() |> Schemas.with_requirements([reference])

    assert {:ok, _} =
             Upgrade.prepare([original, Info.canonical(Consumer)], [replacement, consumer])

    assert {:error, [_ | _]} = Upgrade.prepare([replacement, consumer], [original, consumer])
  end

  test "twenty updates retain only schemas required by the current composition" do
    current = {self(), :series}
    base = Info.canonical(Owner)
    baseline = SchemaStore.stats()

    for revision <- 101..120 do
      owner = base |> Map.delete("digest") |> Map.put("version", revision)
      :ok = SchemaStore.replace(current, Schemas.index([owner]))
      Context.new(owner, :trusted)
      assert SchemaStore.stats().definitions <= baseline.definitions + 1
      assert SchemaStore.stats().holders == baseline.holders + 1
    end

    :ok = SchemaStore.release(current)
    assert SchemaStore.stats() == baseline
  end
end

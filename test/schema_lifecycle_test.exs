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
      contexts = Enum.map(consumers, &Context.new(&1, :trusted, fn _, _, _, _ -> {:ok, "ok"} end))
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

  test "old live rights reject an update even when the new consumer removes that dependency" do
    owner = Info.canonical(Owner)
    caller = Info.canonical(Consumer)
    binding = Context.new(caller, :trusted, fn _, _, _, _ -> {:ok, "ok"} end)
    changed_caller = caller |> Map.delete("digest") |> Map.put("consumes", [])
    broken = owner |> Map.delete("digest") |> Map.put("operations", [])
    assert {:ok, _} = Upgrade.prepare([owner, caller], [broken, changed_caller])

    assert {:error, [_ | _]} =
             Upgrade.prepare([owner, caller], [broken, changed_caller], [binding.consumer])
  end

  test "admission records compatible links for retained older contexts" do
    owner = Info.canonical(Owner)
    caller = Info.canonical(Consumer)
    binding = Context.new(caller, :trusted, fn _, _, _, _ -> {:ok, "ok"} end)
    replacement = owner |> Map.delete("digest") |> Map.put("description", "Changed documentation")
    offered = Schemas.id(replacement)
    required = hd(binding.consumer["consumes"])["schema"]
    assert {:ok, _} = Upgrade.prepare([owner, caller], [replacement, caller], [binding.consumer])
    assert :ok = SchemaStore.approve_bindings([binding.consumer], [replacement, caller])
    assert SchemaStore.approved?(required, offered)
  end

  test "new code cannot require permissions absent from an active older owner context" do
    original = Info.canonical(Owner)
    caller = Info.canonical(Consumer)
    added = hd(original["operations"]) |> Map.put("name", "lookup")
    provider = original |> Map.delete("digest") |> Map.update!("operations", &(&1 ++ [added]))
    updated = Schemas.with_requirements(caller, [Reference.requirement(provider)])
    binding = Context.new(caller, :trusted, fn _, _, _, _ -> {:ok, "ok"} end)

    assert {:ok, _} = Upgrade.prepare([original, caller], [provider, updated])

    assert {:error, [%{reason: :live_context_requires_migration}]} =
             Upgrade.prepare([original, caller], [provider, updated], [binding.consumer])
  end

  test "a monitored holder keeps a revision alive through replacement and releases on exit" do
    owner = Info.canonical(Owner)
    id = Schemas.id(owner)
    installation = {self(), :installation}
    :ok = SchemaStore.replace(installation, Schemas.index([owner]))
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        :ok = SchemaStore.pin(self(), [id])
        send(parent, :pinned)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :pinned
    :ok = SchemaStore.replace(installation, %{})
    assert SchemaStore.fetch!(id)["module"] == owner["module"]
    send(pid, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    # The shared fixture can have other current owners. Its worker lease must be gone.
    assert SchemaStore.promises([owner["module"]]) == []
    :ok = SchemaStore.release(installation)
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

  test "a late track cannot recreate the declaration of a released worker lease" do
    consumer = Info.canonical(Consumer)
    binding = Context.new(consumer, :trusted, fn _, _, _, _ -> {:ok, "ok"} end)
    holder = {self(), make_ref()}
    assert :ok = SchemaStore.pin(holder, binding.schemas)
    assert :ok = SchemaStore.release(holder)
    assert :ok = SchemaStore.track(holder, binding.consumer)
    assert SchemaStore.promises([consumer["module"]], [self()]) == []
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

  test "repeated updates release completed revisions and retain only current and previous" do
    current = {self(), :series}
    previous = {self(), :series_previous}
    base = Info.canonical(Owner)
    baseline = SchemaStore.stats().definitions

    Enum.reduce(1..20, %{}, fn revision, old ->
      owner = base |> Map.delete("digest") |> Map.put("version", revision + 100)
      index = Schemas.index([owner])
      :ok = SchemaStore.replace(previous, old)
      :ok = SchemaStore.replace(current, index)
      assert SchemaStore.stats().definitions <= baseline + 2
      index
    end)

    :ok = SchemaStore.release(current)
    :ok = SchemaStore.release(previous)
    assert SchemaStore.stats().definitions <= baseline
  end
end

defmodule DomainContract.StrictSchemaTest do
  use ExUnit.Case, async: false
  alias DomainContract.Artifact
  alias DomainContract.Compatibility
  alias DomainContract.Info
  alias DomainContract.Runtime
  alias DomainContract.Schemas

  defmodule Owner do
    use DomainContract

    contract do
      version(1)
      responsibility("Owns two independently consumed operations.")

      operation :lookup do
        input_type(%{"id" => :integer})
        output_type(%{id: :integer})
        error_type({:enum, [:missing]})
      end

      operation(:unrelated, input_type: :integer, output_type: :integer)
    end

    def call("lookup", %{"id" => 0}, _), do: {:error, :missing}
    def call("lookup", %{"id" => -1}, _), do: {:error, :unavailable}

    def call("lookup", %{"id" => -2}, _),
      do: raise(DomainContract.InvocationError, reason: {:unavailable, __MODULE__})

    def call("lookup", %{"id" => id}, _), do: {:ok, %{id: id}}
    def call("unrelated", id, _), do: {:ok, id}
  end

  defmodule Consumer do
    use DomainContract

    contract do
      version(1)
      responsibility("Only requires lookup.")
      consumes(Owner, only: [:lookup])
    end

    def lookup(input), do: DomainContract.call(Owner, :lookup, input)
  end

  test "requirements retain only selected operations and do not acquire other rights" do
    consumer = Info.canonical(Consumer)
    [ref] = consumer["consumes"]
    required = Schemas.fetch!(ref, consumer)
    assert Enum.map(required["operations"], & &1["name"]) == ["lookup"]
    assert Consumer.lookup(%{"id" => 2}) == {:ok, %{id: 2}}
    assert Consumer.lookup(%{"id" => 0}) == {:error, :missing}

    assert {:error, {:invalid_contract, :invalid_operation}} =
             Runtime.invoke(Consumer, Owner, :unrelated, 1, nil)

    replacement =
      Owner.__contract__()
      |> Map.update!("operations", &Enum.reject(&1, fn op -> op["name"] == "unrelated" end))

    assert Compatibility.satisfies(replacement, required) == :ok
  end

  test "key representation is strict at every nesting level and remains unchanged" do
    assert {:error, _} = Consumer.lookup(%{id: 2})

    assert :ok =
             Runtime.validate_type(%{items: {:list, %{"id" => :integer}}}, %{
               items: [%{"id" => 2}]
             })

    assert {:error, _} =
             Runtime.validate_type(%{items: {:list, %{"id" => :integer}}}, %{items: [%{id: 2}]})

    assert {:error, _} = Runtime.validate_type(%{"id" => :integer}, %{:id => 2, "id" => 2})

    assert_raise ArgumentError, ~r/all atoms or all strings/, fn ->
      Runtime.validate_type(%{:id => :integer, "name" => :string}, %{})
    end
  end

  test "delivery failures are distinct from the owner's declared business errors" do
    assert {:error, {:invalid_contract, ["lookup", :error]}} = Consumer.lookup(%{"id" => -1})
    assert {:error, {:unavailable, Owner}} = Consumer.lookup(%{"id" => -2})
  end

  test "transport adapters distinguish declared errors, invalid errors and admission failures" do
    assert Runtime.dispatch(Consumer, Owner, :lookup, %{"id" => 0}, nil) == {:error, :missing}

    assert Runtime.dispatch(Consumer, Owner, :lookup, %{"id" => -1}, nil) ==
             {:failure, {:invalid_contract, ["lookup", :error]}}

    assert Runtime.dispatch(Consumer, Owner, :lookup, %{"id" => -2}, nil) ==
             {:failure, {:unavailable, Owner}}

    assert Runtime.dispatch(Consumer, Owner, :unrelated, 1, nil) ==
             {:failure, {:invalid_contract, :invalid_operation}}
  end

  test "untyped containers, open entities and bare application structs are rejected" do
    for type <-
          ~w(opaque any map list global) ++ [["open_entity", "item"], ["struct", "Elixir.Custom"]] do
      refute Artifact.type?(type, ["item"])
    end

    assert {:error, _} = Runtime.validate_type(:opaque, self())
    assert {:error, _} = Runtime.validate_type(:any, fn -> :anything end)
    assert :ok = Runtime.validate_type({:struct, Date}, ~D[2026-11-13])

    assert :ok =
             Runtime.validate_type({:union, [%{id: :integer}, {:struct, Date}]}, ~D[2026-11-13])

    assert {:error, _} = Runtime.validate_type({:dictionary, :integer}, ~D[2026-11-13])
    assert {:error, _} = Runtime.validate_type({:struct, Date}, %{__struct__: Date})
    assert {:error, _} = Runtime.validate_type({:struct, Date}, %{~D[2026-11-13] | month: 25})
    assert :ok = Runtime.validate_type({:struct, DateTime}, ~U[2026-11-13 12:00:00Z])
  end

  test "propagated error unions keep one copy of each alternative and preserve key contracts" do
    original = {:union, [{:enum, [:missing]}, %{id: :integer}, %{"id" => :integer}]}
    imported = Info.type(original)

    propagated =
      Enum.reduce(1..8, imported, fn _, type -> Info.type({:union, [type, imported]}) end)

    assert propagated == imported
    assert Compatibility.subset?(propagated, imported)
    assert Compatibility.subset?(imported, propagated)

    for value <- [:missing, %{id: 1}, %{"id" => 1}] do
      assert :ok = Runtime.validate_type(propagated, value)
    end

    for value <- [:busy, %{id: "1"}, %{"id" => "1"}, %{:id => 1, "id" => 1}] do
      assert {:error, _} = Runtime.validate_type(propagated, value)
    end
  end

  test "adding provider errors is incompatible with callers that cannot handle them" do
    old = Info.canonical(Owner)

    changed =
      update_in(old, ["operations", Access.at(0), "error_type"], fn _ ->
        ["enum", [["atom", "missing"], ["atom", "busy"]]]
      end)

    assert {:error, errors} = Compatibility.satisfies(changed, old)
    assert Enum.any?(errors, &(&1[:direction] == :error))
    assert Compatibility.satisfies(old, changed) == :ok
  end

  test "JSON transport values cannot smuggle Elixir terms or mixed keys" do
    assert :ok = Runtime.validate_type(:json, %{"rows" => [%{"value" => 2}, nil, true]})

    for value <- [
          %{id: 1},
          %{"nested" => %{id: 1}},
          self(),
          fn -> :ok end,
          {:ok, 1},
          :secret,
          <<255>>
        ] do
      assert {:error, _} = Runtime.validate_type(:json, value)
    end

    assert :ok = Runtime.validate_type(:binary, <<255>>)
    assert {:error, _} = Runtime.validate_type(:string, <<255>>)
  end

  test "subscribers depend only on the selected event and its reachable entity graph" do
    provider =
      Owner.__contract__()
      |> Map.delete("digest")
      |> Map.put("entities", [
        %{
          "name" => "event",
          "keys" => "strings",
          "fields" => [%{"name" => "id", "type" => "integer", "optional" => false}]
        }
      ])
      |> Map.put("notifications", [
        %{"name" => "changed", "payload" => ["entity", "event"]},
        %{"name" => "unrelated", "payload" => "string"}
      ])

    selected = Schemas.notification(provider, :changed)
    assert selected["operations"] == []
    assert Enum.map(selected["notifications"], & &1["name"]) == ["changed"]
    assert Enum.map(selected["entities"], & &1["name"]) == ["event"]
    assert Artifact.validate(selected) == :ok
    assert Compatibility.satisfies(provider, selected) == :ok

    changed = put_in(provider, ["notifications", Access.at(1), "payload"], "integer")
    assert Compatibility.satisfies(changed, selected) == :ok
  end

  test "malformed metadata remains invalid even though it is outside execution identity" do
    owner = Owner.__contract__() |> Map.delete("digest")

    for metadata <- [nil, "not metadata", []] do
      assert {:error, :invalid_artifact} = Artifact.validate(Map.put(owner, "metadata", metadata))
    end
  end

  test "private metadata and prose are exported but do not change execution identity" do
    owner = Owner.__contract__()

    changed =
      owner
      |> Map.delete("digest")
      |> Map.put("metadata", %{"architecture" => %{"owns" => ["Elixir.Private.Helper"]}})
      |> Map.put("responsibility", "Reworded responsibility")
      |> put_in(["operations", Access.at(0), "description"], "New operation documentation")

    assert Schemas.id(owner) == Schemas.id(changed)
    assert Schemas.index([owner, changed]) == Schemas.index([owner])
    [exported] = Schemas.unbundle(Schemas.bundle([changed]))
    assert exported["metadata"] == changed["metadata"]
    assert exported["operations"] == changed["operations"]
    assert exported["responsibility"] == changed["responsibility"]
    assert Artifact.validate(exported) == :ok
  end
end

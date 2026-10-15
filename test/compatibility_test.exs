defmodule DomainContract.CompatibilityTest do
  use ExUnit.Case, async: false
  alias DomainContract.Compatibility
  alias DomainContract.Info
  alias DomainContract.Port
  alias DomainContract.Stub

  defmodule Provider do
    use DomainContract

    domain :tasks do
      entity :lookup do
        field(:id, :string)
      end

      entity :task do
        field(:id, :string)
        field(:status, {:enum, ["started", "finished"]})
        field(:title, :string)
      end

      interface :capability do
        name("tasks")
        version(2)
        operation(:get, input: :lookup, output: :task)
      end
    end
  end

  defmodule Consumer do
    use DomainContract

    domain :chat do
      consumes :capability do
        name("tasks")
        version(1)

        operation :get do
          input_entity :lookup do
            field(:id, :string)
          end

          output_entity :summary do
            field(:id, :string)
            field(:status, :string)
          end
        end
      end
    end
  end

  setup do
    {:ok, provider: export(Provider), consumer: export(Consumer)}
  end

  test "consumer declarations compose inline schemas and export version 3", context do
    assert context.consumer["format_version"] == 3
    assert context.consumer["interfaces"] == []
    assert :ok = Compatibility.check([context.provider, context.consumer])
  end

  test "missing operation, provider and cumulative version are explicit", context do
    assert {:error, [%{reason: :missing_provider}]} = Compatibility.check([context.consumer])
    provider = put_in(context.provider, ["interfaces", Access.at(0), "version"], 0)

    assert {:error, [%{reason: :version_too_old}]} =
             Compatibility.check([provider, context.consumer])

    provider = put_in(context.provider, ["interfaces", Access.at(0), "operations"], [])

    assert {:error, [%{reason: :missing_operation}]} =
             Compatibility.check([provider, context.consumer])
  end

  test "a new required request field breaks an unchanged consumer", context do
    provider = update_field(context.provider, "lookup", &(&1 ++ [field("workspace", "string")]))

    assert {:error, [%{reason: :incompatible_input}]} =
             Compatibility.check([provider, context.consumer])

    provider =
      update_field(context.provider, "lookup", &(&1 ++ [field("workspace", "string", true)]))

    assert :ok = Compatibility.check([provider, context.consumer])
  end

  test "missing or optional required response fields break the consumer", context do
    for fields <- [
          fn fields -> Enum.reject(fields, &(&1["name"] == "status")) end,
          fn fields ->
            Enum.map(
              fields,
              &if(&1["name"] == "status", do: Map.put(&1, "optional", true), else: &1)
            )
          end
        ] do
      provider = update_field(context.provider, "task", fields)

      assert {:error, [%{reason: :incompatible_output}]} =
               Compatibility.check([provider, context.consumer])
    end
  end

  test "provider reply variants must all be accepted by the consumer", context do
    consumer =
      update_field(context.consumer, "summary", fn fields ->
        Enum.map(
          fields,
          &if(&1["name"] == "status", do: Map.put(&1, "type", ["enum", ["started"]]), else: &1)
        )
      end)

    assert {:error, [%{reason: :incompatible_output}]} =
             Compatibility.check([context.provider, consumer])
  end

  test "multiple providers cannot silently resolve the same interface", context do
    assert {:error, [%{reason: :multiple_providers}]} =
             Compatibility.check([context.provider, context.provider, context.consumer])
  end

  test "real call adapter and provider stub validate both boundaries" do
    dispatch =
      Stub.dispatcher(Provider, %{
        {"tasks", "get"} => fn %{"id" => id} ->
          {:ok, %{"id" => id, "status" => "started", "title" => "Local task"}}
        end
      })

    assert {:ok, %{"id" => "one", "title" => "Local task"}} =
             Port.call(Consumer, {:capability, "tasks"}, "get", %{"id" => "one"}, dispatch)

    assert {:error, {:invalid_contract, _}} =
             Port.call(Consumer, {:capability, "tasks"}, "get", %{"id" => 4}, dispatch)

    assert {:error, :invalid_operation} =
             Port.call(Consumer, {:capability, "tasks"}, "absent", %{}, dispatch)

    invalid =
      Stub.dispatcher(Provider, %{{"tasks", "get"} => fn _ -> {:ok, %{"id" => "one"}} end})

    assert {:error, {:invalid_contract, _}} =
             Port.call(Consumer, {:capability, "tasks"}, "get", %{"id" => "one"}, invalid)
  end

  defp export(module), do: module |> Info.json() |> Jason.decode!()

  defp field(name, type, optional \\ false),
    do: %{"name" => name, "type" => type, "optional" => optional}

  defp update_field(contract, entity, fun) do
    update_in(contract, ["entities", Access.all()], fn declaration ->
      if declaration["name"] == entity,
        do: Map.update!(declaration, "fields", fun),
        else: declaration
    end)
  end
end

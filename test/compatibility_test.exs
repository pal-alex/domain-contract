defmodule DomainContract.CompatibilityTest do
  use ExUnit.Case, async: false
  alias DomainContract.{Compatibility, Context, Implementation, Info, Reference}

  defmodule Public do
    use DomainContract

    domain :tasks do
      interface :capability do
        name("tasks")
        version(2)

        operation :get do
          input_entity :lookup do
            field(:id, :string)
          end

          output_entity :task do
            field(:id, :string)
            field(:status, {:enum, ["started", "finished"]})
          end
        end

        operation :count do
          input_entity :query do
          end

          output_entity :count do
            field(:total, :integer)
          end
        end
      end
    end
  end

  defmodule Consumer do
    use DomainContract

    domain :chat do
      consumes("tasks", version: 2, contract: Public)
    end
  end

  defmodule OptionalConsumer do
    use DomainContract

    domain :chat do
      consumes("tasks", version: 2, contract: Public, optional: true)
    end
  end

  defmodule AlternativeContract do
    use DomainContract

    domain :custom_tasks do
      implements("tasks", version: 2, contract: Public)
    end
  end

  defmodule Default do
    use Implementation, contract: Public
    def call("get", %{"id" => id}, _), do: {:ok, %{"id" => id, "status" => "started"}}
    def call("count", %{}, _), do: {:ok, %{"total" => 1}}
  end

  defmodule Alternative do
    use Implementation, contract: AlternativeContract

    def call(operation, input, context) when operation in @contract_operations,
      do: Default.call(operation, input, context)
  end

  defmodule IncompleteClaim do
    def call(_, _, _), do: {:error, :not_implemented}
    def __domain_contracts__, do: Info.canonical(Public) |> List.wrap()
    def __domain_contract_operations__, do: ["get"]
  end

  defmodule MalformedClaim do
    def call(_, _, _), do: {:error, :not_implemented}
    def __domain_contracts__, do: :malformed
    def __domain_contract_operations__, do: []
  end

  test "consumes exports a reference and the complete immutable public contract, without local schemas" do
    contract = Info.canonical(Consumer)
    assert contract["format_version"] == 4
    assert contract["entities"] == []
    assert contract["interfaces"] == []
    [reference] = contract["consumes"]
    refute Map.has_key?(reference, "operations")
    assert reference["definition"] == Reference.resolve(Public, "tasks", 2)
    assert length(reference["definition"]["interface"]["operations"]) == 2
    assert :ok = Compatibility.check([Public, Consumer])
  end

  test "independent packages validate complete snapshots without providers or an installed authority catalog" do
    for declaration <- [Consumer, OptionalConsumer, AlternativeContract] do
      artifact = Info.canonical(declaration)
      assert :ok = Compatibility.validate([artifact])
    end

    assert :ok =
             Compatibility.validate([
               Info.canonical(Consumer),
               Info.canonical(AlternativeContract)
             ])

    assert {:error, errors} = Compatibility.check([Consumer, AlternativeContract])
    assert Enum.any?(errors, &(&1.reason == :unknown_contract))
    assert :ok = Compatibility.check([Consumer, AlternativeContract], [Public])
    assert {:error, [%{reason: :missing_provider}]} = Compatibility.check([Consumer], [Public])
  end

  test "independent package validation rejects conflicting embedded snapshots and corrupt declarations" do
    changed =
      Map.put(Info.canonical(Public), "description", "Different authoritative obligations.")

    alternative =
      put_in(
        Info.canonical(AlternativeContract),
        ["implements", Access.at(0), "definition"],
        Reference.resolve(changed, "tasks", 2)
      )

    assert :ok = Compatibility.validate([alternative])

    assert {:error, [%{reason: :conflicting_contract}]} =
             Compatibility.validate([Consumer, alternative])

    corrupted =
      put_in(
        Info.canonical(Consumer),
        ["consumes", Access.at(0), "definition", "digest"],
        "invalid"
      )

    assert {:error, [%{contract: 0, reason: :invalid_artifact}]} =
             Compatibility.validate([corrupted])

    assert {:error, [%{reason: :conflicting_contract}]} =
             Compatibility.validate([Public, alternative])
  end

  test "both implementations use the same reference, package metadata, and unchanged consumer" do
    for {provider, declaration} <- [{Default, Public}, {Alternative, AlternativeContract}] do
      assert :ok = Implementation.check(provider, [declaration])
      assert :ok = Compatibility.check(provider.__domain_contracts__() ++ [Consumer], [Public])
      context = context(Consumer, provider)

      assert {:ok, %{"id" => "one", "status" => "started"}} =
               DomainContract.call(context, "tasks", "get", %{"id" => "one"})

      assert {:ok, %{"total" => 1}} = DomainContract.call(context, "tasks", "count", %{})
    end

    assert :ok = Implementation.check(Default)
  end

  test "packaged BEAM conformance is checked without activating or loading the candidate" do
    module = Module.concat(__MODULE__, "Packaged#{System.unique_integer([:positive])}")

    [{^module, beam}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use DomainContract.Implementation, contract: #{inspect(AlternativeContract)}
        def call(operation, _input, _context) when operation in @contract_operations, do: {:error, :business_failure}
      end
      """)

    :code.delete(module)
    :code.purge(module)
    assert :code.is_loaded(module) == false
    assert :ok = Implementation.check_beam(beam, [AlternativeContract])

    assert {:error, {:invalid_contract, :implementation_metadata_mismatch}} =
             Implementation.check_beam(beam, [Public])

    assert {:error, {:invalid_contract, :invalid_implementation}} =
             Implementation.check_beam("invalid beam", [Public])

    assert :code.is_loaded(module) == false
  end

  test "the whole interface is checked, not only operations currently used by a consumer" do
    assert_raise CompileError, ~r/missing public call\/3 operations: \["count"\]/, fn ->
      compile("""
      use DomainContract.Implementation, contract: #{inspect(Public)}
      def call("get", _, _), do: {:error, :not_found}
      def call(_, _, _), do: {:error, :invalid_operation}
      """)
    end
  end

  test "wrong invocation signature and private entry points cannot implement a contract" do
    for implementation <- ["def call(_, _), do: :ok", "defp call(_, _, _), do: :ok"] do
      assert_raise CompileError, ~r/incomplete DomainContract implementation/, fn ->
        compile(
          "use DomainContract.Implementation, contract: #{inspect(Public)}\n" <> implementation
        )
      end
    end
  end

  test "negative and disjoint operation guards do not advertise missing operations" do
    for guard <- [
          "operation not in @contract_operations",
          "operation in [\"get\"] and operation in [\"count\"]"
        ] do
      assert_raise CompileError, ~r/incomplete DomainContract implementation/, fn ->
        compile("""
        use DomainContract.Implementation, contract: #{inspect(Public)}
        def call(operation, _, _) when #{guard}, do: {:error, :unreachable}
        """)
      end
    end
  end

  test "exact versions, required availability, and optional availability are explicit" do
    assert {:error, [%{reason: :missing_provider}]} = Compatibility.check([Consumer], [Public])
    assert :ok = Compatibility.check([OptionalConsumer], [Public])
    newer = update_in(Info.canonical(Public), ["interfaces", Access.at(0), "version"], &(&1 + 1))
    assert {:error, errors} = Compatibility.check([newer, Consumer], [Public])
    assert Enum.any?(errors, &(&1.reason == :incorrect_version))

    unavailable =
      Context.new(OptionalConsumer, "chat", fn name, _, _, _ -> {:error, {:unavailable, name}} end)

    assert {:error, {:unavailable, "tasks"}} =
             DomainContract.call(unavailable, "tasks", "count", %{})
  end

  test "a provider with the same name/version but a different kind has the wrong identity" do
    provider = put_in(Info.canonical(Public), ["interfaces", Access.at(0), "kind"], "other")

    assert {:error, [%{reason: :incorrect_identity}]} =
             Compatibility.check([provider, Consumer], [Public])
  end

  test "duplicate providers and conflicting identities are rejected before activation" do
    assert {:error, [%{reason: :multiple_providers}]} =
             Compatibility.check([Public, AlternativeContract], [Public])

    modified =
      update_in(
        Info.canonical(Public),
        ["interfaces", Access.at(0), "operations"],
        &Enum.reject(&1, fn op -> op["name"] == "count" end)
      )

    assert {:error, errors} = Compatibility.check([modified, Consumer], [Public])
    assert Enum.any?(errors, &(&1.reason == :conflicting_contract))

    redefinition =
      Info.canonical(AlternativeContract)
      |> put_in(
        ["implements", Access.at(0), "definition"],
        Reference.resolve(modified, "tasks", 2)
      )

    assert {:error, [%{reason: :conflicting_contract}]} =
             Compatibility.check([redefinition], [Public])

    assert {:error, [%{reason: :unknown_contract}]} = Compatibility.check([AlternativeContract])
  end

  test "domain-wide behavioral obligations participate in the immutable public identity" do
    changed =
      Map.put(
        Info.canonical(Public),
        "description",
        "The domain preserves accepted requests across restart."
      )

    original = Reference.resolve(Public, "tasks", 2)
    replacement = Reference.resolve(changed, "tasks", 2)
    assert replacement["description"] == changed["description"]
    assert original["digest"] != replacement["digest"]
    assert {:error, errors} = Compatibility.check([changed, Consumer], [Public])
    assert Enum.any?(errors, &(&1.reason == :conflicting_contract))
  end

  test "metadata tampering and incomplete package claims are rejected" do
    assert {:error, {:invalid_contract, :missing_operation}} =
             Implementation.check(IncompleteClaim)

    assert {:error, {:invalid_contract, :invalid_implementation}} =
             Implementation.check(MalformedClaim)

    assert {:error, {:invalid_contract, :implementation_metadata_mismatch}} =
             Implementation.check(Default, [AlternativeContract])

    artifact = Info.canonical(AlternativeContract)
    corrupted = put_in(artifact, ["implements", Access.at(0), "definition", "digest"], "corrupt")
    assert {:error, [%{reason: :invalid_artifact}]} = Compatibility.check([corrupted], [Public])

    projection = put_in(Info.canonical(Consumer), ["consumes", Access.at(0), "operations"], [])
    assert {:error, [%{reason: :invalid_artifact}]} = Compatibility.check([projection], [Public])

    malformed =
      put_in(
        Info.canonical(Public),
        ["entities", Access.at(0), "fields", Access.at(0), "type"],
        "invented"
      )

    assert {:error, [%{reason: :invalid_artifact}]} = Compatibility.check([malformed])
    legacy = %{Info.canonical(Consumer) | "format_version" => 3}
    assert {:error, [%{reason: :invalid_artifact}]} = Compatibility.check([legacy])
  end

  test "an optional provider, when present, must match the exact authoritative interface" do
    newer = update_in(Info.canonical(Public), ["interfaces", Access.at(0), "version"], &(&1 + 1))
    assert {:error, errors} = Compatibility.check([OptionalConsumer, newer], [Public])
    assert Enum.any?(errors, &(&1.reason == :incorrect_version))
  end

  test "stubs use the canonical four-argument dispatcher and reject invented successful output" do
    stub =
      DomainContract.Stub.dispatcher(AlternativeContract, %{
        {"tasks", "get"} => fn input -> {:ok, Map.put(input, "status", "started")} end
      })

    context = Context.new(Consumer, "chat", stub)

    assert {:ok, %{"status" => "started"}} =
             DomainContract.call(context, "tasks", "get", %{"id" => "one"})

    assert {:error, :not_stubbed} = DomainContract.call(context, "tasks", "count", %{})

    stub =
      DomainContract.Stub.dispatcher(Public, %{
        {"tasks", "count"} => fn _ -> {:ok, %{"total" => "incorrect"}} end
      })

    assert {:error, {:invalid_contract, _}} =
             DomainContract.call(Context.new(Consumer, "chat", stub), "tasks", "count", %{})
  end

  test "canonical invocation rejects invalid input and complete output without calling the dispatcher early" do
    dispatch = fn _, _, input, _ ->
      send(self(), :dispatched)
      {:ok, input}
    end

    context = Context.new(Consumer, "chat", dispatch)

    assert {:error, {:invalid_contract, _}} =
             DomainContract.call(context, "tasks", "get", %{"id" => 7})

    refute_received :dispatched

    assert {:error, {:invalid_contract, _}} =
             DomainContract.call(context, "tasks", "get", %{"id" => "one"})

    assert_received :dispatched

    extra =
      Context.new(Consumer, "chat", fn _, _, _, _ ->
        {:ok, %{"id" => "one", "status" => "started", "extra" => true}}
      end)

    assert {:error, {:invalid_contract, _}} =
             DomainContract.call(extra, "tasks", "get", %{"id" => "one"})
  end

  test "undeclared dependencies and operations cannot reach dispatch; legacy Port invocation is gone" do
    context = context(Consumer, Default)

    assert {:error, {:invalid_contract, :undeclared_dependency}} =
             DomainContract.call(context, "other", "get", %{})

    assert {:error, {:invalid_contract, :invalid_operation}} =
             DomainContract.call(context, "tasks", "absent", %{})

    refute function_exported?(DomainContract.Port, :call, 5)
    assert {:error, {:invalid_contract, :context}} = DomainContract.call(%{}, "tasks", "get", %{})
  end

  test "business errors retain arbitrary reasons, and invalid dispatcher results are distinct" do
    reason = %{type: :business_failure, value: {:nested, 3}}
    context = Context.new(Consumer, "chat", fn _, _, _, _ -> {:error, reason} end)
    assert {:error, ^reason} = DomainContract.call(context, "tasks", "count", %{})
    context = Context.new(Consumer, "chat", fn _, _, _, _ -> :ok end)

    assert {:error, {:invalid_contract, :invalid_result}} =
             DomainContract.call(context, "tasks", "count", %{})
  end

  test "platform contexts retain their source and trusted caller during dispatch" do
    binding =
      Context.new(Consumer, "chat", fn _, _, _, outer ->
        assert outer.domain_contract.caller == "chat"
        {:ok, %{"total" => outer.source.total}}
      end)

    outer = %{domain_contract: binding, source: %{total: 6}, request: %{"caller" => "forged"}}
    assert {:ok, %{"total" => 6}} = DomainContract.call(outer, "tasks", "count", %{})
  end

  @tag :tmp_dir
  test "independent packages consume canonical files without depending on a provider module", %{
    tmp_dir: root
  } do
    path = Path.join(root, "contracts.json")
    File.write!(path, Jason.encode!([Info.canonical(Public)]))

    module =
      compile("""
      use DomainContract
      domain :independent do
        consumes "tasks", version: 2, contract: #{inspect(path)}
        implements "tasks", version: 2, contract: #{inspect(path)}
      end
      """)

    assert :ok = Compatibility.check([module], [Public])
    assert {:external_resource, [path]} in module.module_info(:attributes)
  end

  test "consumer projections and reference schema redefinitions fail compilation" do
    assert_raise CompileError, ~r/cannot compile module/, fn ->
      compile("""
      use DomainContract
      domain :bad do
        consumes "tasks", version: 2, contract: #{inspect(Public)} do
          operation :get, input: :lookup, output: :task
        end
      end
      """)
    end

    assert_raise Spark.Error.DslError, ~r/unknown contract/, fn ->
      compile(
        "use DomainContract\ndomain :bad do\n consumes \"tasks\", version: 99, contract: #{inspect(Public)}\nend"
      )
    end
  end

  defp context(consumer, provider) do
    Context.new(consumer, "chat", fn _name, operation, input, context ->
      provider.call(operation, input, context)
    end)
  end

  defp compile(body) do
    module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")
    Code.compile_string("defmodule #{inspect(module)} do\n#{body}\nend", "contract_fixture.ex")
    module
  end
end

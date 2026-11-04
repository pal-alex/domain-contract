defmodule DomainContract.ArchitectureTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias DomainContract.Architecture

  @moduletag :tmp_dir
  @fixture Path.expand("fixtures/architecture/lib/example.ex", __DIR__)
  @inventory ArchitectureExample.Inventory
  @checkout ArchitectureExample.Checkout
  @helper ArchitectureExample.Inventory.Helper
  @record ArchitectureExample.Inventory.Record

  test "golden path: declared dependency, exact native API, same-owner helpers and exported record",
       ctx do
    compile!(ctx, source())
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
    assert apply(@checkout, :run, [42]) == struct(@record, id: 42)
  end

  test "an aliased call to an unexported helper fails even with the owner dependency", ctx do
    compile!(ctx, String.replace(source(), "Stock.fetch(id)", "Stock.Helper.fetch(id)"))
    errors = errors()

    assert [%{module: @checkout, target: {@helper, :fetch, 1}, kind: :call, line: line}] =
             reasons(errors, :private_reference)

    assert line > 0
    assert reasons(errors, :undeclared_dependency) == []
  end

  test "a public native function still requires an explicit dependency", ctx do
    compile!(ctx, String.replace(source(), "uses: [Stock]", "uses: []"))
    assert [%{target: {@inventory, :fetch, 1}}] = reasons(errors(), :undeclared_dependency)
  end

  test "an unused extra public arity on an owner fails", ctx do
    compile!(ctx, inject(source(), @inventory, "def fetch(id, extra), do: {id, extra}"))

    assert [%{module: @inventory, function: {:fetch, 2}}] =
             reasons(errors(), :extra_public_function)
  end

  test "a public function with an internal-looking name is not exempt", ctx do
    compile!(ctx, inject(source(), @inventory, "def __domain_contract_backdoor__, do: :leak"))

    assert [%{function: {:__domain_contract_backdoor__, 0}}] =
             reasons(errors(), :extra_public_function)
  end

  test "a capture is checked at its real arity", ctx do
    text =
      String.replace(
        source(),
        "def run(id), do: Stock.fetch(id)",
        "def run(_), do: &Stock.Helper.fetch/1"
      )

    compile!(ctx, text)

    assert [%{target: {@helper, :fetch, 1}, kind: :capture}] =
             reasons(errors(), :private_reference)
  end

  test "a declared remote capture does not invent a zero-arity reference", ctx do
    text =
      String.replace(
        source(),
        "def run(id), do: Stock.fetch(id)",
        "def run(_), do: &Stock.fetch/1"
      )

    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "delegates cannot expose another owner's helper", ctx do
    text =
      String.replace(
        source(),
        "def run(id), do: Stock.fetch(id)",
        "defdelegate run(id), to: Stock.Helper, as: :fetch"
      )

    compile!(ctx, text)
    assert [%{target: {@helper, :fetch, 1}}] = reasons(errors(), :private_reference)
  end

  test "literal apply has the same boundary as a direct call", ctx do
    compile!(
      ctx,
      String.replace(source(), "Stock.fetch(id)", "apply(Stock.Helper, :fetch, [id])")
    )

    assert [%{target: {@helper, :fetch, 1}, kind: :apply}] = reasons(errors(), :private_reference)
  end

  test "exporting one helper arity does not export its overload", ctx do
    text =
      String.replace(
        source(),
        "exports: %{",
        "exports: %{ArchitectureExample.Inventory.Helper => [fetch: 1],"
      )

    text = inject(text, @helper, "def fetch(id, extra), do: {id, extra}")
    compile!(ctx, String.replace(text, "Stock.fetch(id)", "Stock.Helper.fetch(id, :extra)"))
    assert [%{target: {@helper, :fetch, 2}}] = reasons(errors(), :private_reference)
  end

  test "unknown dynamic dispatch fails instead of silently creating a dependency", ctx do
    compile!(ctx, String.replace(source(), "Stock.fetch(id)", "id.fetch(1)"))
    assert [%{module: @checkout, caller: {:run, 1}}] = reasons(errors(), :dynamic_dispatch)
  end

  test "dynamic apply and anonymous function invocation are surfaced", ctx do
    compile!(ctx, String.replace(source(), "Stock.fetch(id)", "{apply(Stock, id, []), id.()}"))
    assert length(reasons(errors(), :dynamic_dispatch)) == 2
  end

  test "omitting parentheses does not hide dynamic module dispatch", ctx do
    compile!(ctx, String.replace(source(), "Stock.fetch(id)", "id.secret"))
    assert [%{module: @checkout}] = reasons(errors(), :dynamic_dispatch)
  end

  test "a new module in the app inventory fails strict coverage", ctx do
    compile!(
      ctx,
      source() <> "\ndefmodule ArchitectureExample.Orphan do\n def read, do: :ok\nend\n"
    )

    assert [%{module: ArchitectureExample.Orphan}] = reasons(errors(), :unowned_module)
    assert Architecture.check_application(:architecture_example) == :ok
  end

  test "proven map access is data while an unguarded dot access remains dynamic", ctx do
    text =
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run(%{} = id), do: id.field
      def run(id) when is_map(id), do: id.field
      def run(id), do: id.field
      """)

    compile!(ctx, text)
    assert [%{dispatch: "id.field"}] = reasons(errors(), :dynamic_dispatch)
  end

  test "map proofs stay inside their guard branches and variable versions", ctx do
    text =
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run(id) do
        case id do
          value when is_map(value) -> value.field
          value -> value.field
        end
        value = %{field: 1}
        _ = value.field
        value = id
        value.field
      end
      """)

    compile!(ctx, text)
    assert length(reasons(errors(), :dynamic_dispatch)) == 2
  end

  test "an or guard does not prove a receiver is always a map", ctx do
    text =
      String.replace(
        source(),
        "def run(id), do: Stock.fetch(id)",
        "def run(id) when is_map(id) or is_atom(id), do: id.field"
      )

    compile!(ctx, text)
    assert [%{dispatch: "id.field"}] = reasons(errors(), :dynamic_dispatch)
  end

  test "with map and struct patterns prove later qualifiers and the successful body", ctx do
    text =
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run(id) do
        with %{} = record <- id,
             true <- record.field,
             %Stock.Record{} = result <- record.result do
          result.id
        end
      end
      """)

    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "with proofs do not reach preceding expressions, else clauses or rebound variables", ctx do
    text =
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run(id) do
        with value <- id,
             _ <- value.before,
             %{} = value <- value,
             _ <- value.proven,
             value <- id do
          value.rebound
        else
          value -> value.failed
        end
      end
      """)

    compile!(ctx, text)

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["value.before", "value.failed", "value.rebound"]
  end

  test "comprehension patterns prove elements only after their generator", ctx do
    compile!(
      ctx,
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run(id) do
        for %{nested: %{}} = item <- id do
          item.nested.field
        end
        for item <- %{a: 1} do
          item.unknown
        end
        id.outside
      end
      """)
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["id.outside", "item.unknown"]
  end

  test "map aliases and copies preserve nested map pattern facts", ctx do
    compile!(
      ctx,
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run(%{profile: %{settings: %{}}} = first = second) do
        copy = second
        {left, right} = {first, copy}
        {left.profile.settings.field, right.profile.settings.field}
      end
      """)
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "case patterns prove the original subject only in the successful branch", ctx do
    compile!(
      ctx,
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run(id) do
        case id do
          %{nested: %{}} = copy -> {id.nested.field, copy.nested.field}
          _ -> id.unsafe
        end
        id.after_case
      end
      """)
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["id.after_case", "id.unsafe"]
  end

  test "case variable patterns inherit a proven subject shape", ctx do
    compile!(
      ctx,
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run(%{nested: %{}} = id) do
        case id do
          value -> value.nested.field
        end
      end
      """)
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "map matches do not prove earlier reads or their right hand side", ctx do
    compile!(
      ctx,
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run(id) do
        value = id
        _ = value.before
        %{} = value = value.result
        _ = value.proven
        value = id
        value.rebound
      end
      """)
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["value.before", "value.rebound", "value.result"]
  end

  test "unknown nested fields, updates and computed map keys cannot prove module reads", ctx do
    compile!(
      ctx,
      String.replace(source(), "def run(id), do: Stock.fetch(id)", """
      def run({key, id}) do
        data = %{nested: %{}}
        data = %{data | nested: id}
        _ = data.nested.updated
        data = %{:nested => %{}, key => id}
        data.nested.computed
      end
      """)
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["data.nested.computed", "data.nested.updated"]
  end

  test "local literal map returns prove data without hiding references in their bodies", ctx do
    text =
      source()
      |> String.replace("Stock.fetch(id)", "marks(id).nested.field")
      |> inject(@checkout, """
      defp marks(:first) do
        _ = ArchitectureExample.Inventory.Helper.fetch(1)
        %{nested: %{field: 1}}
      end
      defp marks(_), do: %{nested: %{field: 2}}
      """)

    compile!(ctx, text)
    assert reasons(errors(), :dynamic_dispatch) == []

    assert [%{caller: {:marks, 1}, target: {@helper, :fetch, 1}}] =
             reasons(errors(), :private_reference)
  end

  test "local result proofs require every clause to agree, including nested fields", ctx do
    text =
      source()
      |> String.replace("Stock.fetch(id)", "{marks(id).field, nested_marks(id).nested.field}")
      |> inject(@checkout, """
      defp marks(:first), do: %{field: 1}
      defp marks(module), do: module
      defp nested_marks(:first), do: %{nested: %{field: 1}}
      defp nested_marks(module), do: %{nested: module}
      """)

    compile!(ctx, text)

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["marks(id).field", "nested_marks(id).nested.field"]
  end

  test "an exact callback gateway permits only its reviewed invocation", ctx do
    compile!(ctx, gateway_source())
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "callback gateways cannot authorize a different arity or a static private call", ctx do
    text =
      gateway_source()
      |> String.replace(
        "def run(id), do: id.(1)",
        "def run(id), do: {id.(1), id.(1, 2), Stock.Helper.secret()}"
      )

    compile!(ctx, text)
    assert [%{dispatch: "id.(1, 2)"}] = reasons(errors(), :dynamic_dispatch)
    assert [%{target: {@helper, :secret, 0}}] = reasons(errors(), :private_reference)
  end

  test "stale gateways fail instead of accumulating exemptions", ctx do
    compile!(
      ctx,
      String.replace(
        gateway_source(),
        "def run(id), do: id.(1)",
        "def run(id), do: Stock.fetch(id)"
      )
    )

    assert [%{reason: :unused_gateway}] = errors()
  end

  test "captured caller-context gateways do not invent a lexical dependency", ctx do
    dispatch = "DomainContract.invoke(nil, ArchitectureExample.Inventory, \"fetch\", id)"

    text =
      contract_source()
      |> String.replace("consumes(Stock)", "")
      |> String.replace("native: [run: 1]", """
      native: [run: 1], gateways: [%{
        module: ArchitectureExample.Checkout, function: :run, arity: 1,
        kind: :contract, dispatch: #{inspect(dispatch)},
        reason: "This test models a reusable port; runtime verifies the supplied context."
      }]
      """)

    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "a declared macro uses its source arity rather than the encoded BEAM arity", ctx do
    text =
      inject(source(), @inventory, "defmacro sample(value), do: value")
      |> String.replace("native: [fetch: 1]", "native: [fetch: 1, sample: 1]")

    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "cross-application native calls require the external owner's exact exports", ctx do
    compile!(ctx, String.replace(source(), "Stock.fetch(id)", "Stock.Helper.fetch(id)"))
    split_application!(ctx)
    assert [%{target: {@helper, :fetch, 1}}] = reasons(errors(), :private_reference)
  end

  test "discovering an external owner does not approve an undeclared dependency", ctx do
    compile!(ctx, String.replace(source(), "uses: [Stock]", "uses: []"))
    split_application!(ctx)
    assert [%{target: {@inventory, :fetch, 1}}] = reasons(errors(), :undeclared_dependency)
  end

  test "explicit external contract dependencies pass", ctx do
    compile!(ctx, contract_source())
    split_application!(ctx)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  defp split_application!(ctx) do
    for {app, modules} <- [
          architecture_example: [@checkout],
          architecture_stock: [@inventory, @helper, @record]
        ] do
      File.write!(
        Path.join([ctx.tmp_dir, "ebin", "#{app}.app"]),
        :io_lib.format(~c"~tp.~n", [{:application, app, [modules: modules]}])
      )
    end
  end

  defp gateway_source do
    source()
    |> String.replace("Stock.fetch(id)", "id.(1)")
    |> String.replace("native: [run: 1]", """
    native: [run: 1], gateways: [%{
      module: ArchitectureExample.Checkout, function: :run, arity: 1,
      kind: :callback, dispatch: "id.(1)",
      reason: "Invoke the callback supplied by the caller with the item ID."
    }]
    """)
  end

  test "a nonexistent helper cannot pass just because its namespace has an owner", ctx do
    text =
      String.replace(
        source(),
        "def fetch(id), do: ArchitectureExample.Inventory.Helper.fetch(id)",
        "@compile {:no_warn_undefined, ArchitectureExample.Inventory.Missing}\n def fetch(id), do: ArchitectureExample.Inventory.Missing.fetch(id)"
      )

    compile!(ctx, text)

    assert [%{target: {ArchitectureExample.Inventory.Missing, :fetch, 1}}] =
             reasons(errors(), :unresolved_module)
  end

  test "existing Owned annotations assign an out-of-namespace helper", ctx do
    compile!(
      ctx,
      source() <>
        """

        defmodule ArchitectureExample.LegacyHelper do
          use DomainContract.Owned, owner: ArchitectureExample.Inventory
          def read(id), do: ArchitectureExample.Inventory.Helper.fetch(id)
        end
        """
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "an Owned annotation cannot publish a helper across owners", ctx do
    text =
      String.replace(source(), "Stock.fetch(id)", "ArchitectureExample.LegacyHelper.read(id)")

    compile!(
      ctx,
      text <>
        """

        defmodule ArchitectureExample.LegacyHelper do
          use DomainContract.Owned, owner: ArchitectureExample.Inventory
          def read(id), do: ArchitectureExample.Inventory.Helper.fetch(id)
        end
        """
    )

    assert [%{target: {ArchitectureExample.LegacyHelper, :read, 1}}] =
             reasons(errors(), :private_reference)
  end

  test "Owned annotations cannot contradict the nearest namespace owner", ctx do
    compile!(
      ctx,
      source() <>
        """

        defmodule ArchitectureExample.Checkout.Helper do
          use DomainContract.Owned, owner: ArchitectureExample.Inventory
          def read, do: :ok
        end
        """
    )

    assert [%{module: ArchitectureExample.Checkout.Helper}] =
             reasons(errors(), :conflicting_ownership)
  end

  test "the closest owner wins and duplicate namespace claims fail", ctx do
    text =
      String.replace(
        source(),
        "native: [fetch: 1],",
        "owns: [ArchitectureExample], native: [fetch: 1],"
      )

    text = String.replace(text, "uses: [Stock],", "owns: [ArchitectureExample], uses: [Stock],")
    compile!(ctx, text)
    assert [%{prefix: "Elixir.ArchitectureExample"}] = reasons(errors(), :conflicting_ownership)
  end

  test "an additional namespace can be owned without swallowing a nested owner", ctx do
    text =
      String.replace(
        source(),
        "native: [fetch: 1],",
        "owns: [ArchitectureExample], native: [fetch: 1],"
      )

    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "struct construction and patterns need the owner's exported record", ctx do
    text =
      String.replace(
        source(),
        "def run(id), do: Stock.fetch(id)",
        "def run(%Stock.Record{id: id}), do: %Stock.Record{id: id}"
      )

    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "unexported struct references cannot hide behind compile-time expansion", ctx do
    text =
      String.replace(
        source(),
        "ArchitectureExample.Inventory.Record => [__struct__: 0, __struct__: 1]",
        "ArchitectureExample.Inventory.Record => []"
      )

    text = String.replace(text, "Stock.fetch(id)", "%Stock.Record{id: id}")
    compile!(ctx, text)

    assert [%{target: {@record, :__struct__, 0}, kind: :struct}] =
             reasons(errors(), :private_reference)
  end

  test "contract operations expose only call/3 and consumes supplies the dependency", ctx do
    compile!(ctx, contract_source("Stock.call(\"fetch\", id, nil)"))
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "explicit invoke checks a real declared operation without starting its application", ctx do
    compile!(ctx, contract_source())
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "invoke cannot replace consumes with native uses", ctx do
    text =
      contract_source()
      |> String.replace("consumes(Stock)", "")
      |> String.replace("native: [run: 1]", "uses: [Stock], native: [run: 1]")

    compile!(ctx, text)

    assert [%{module: @checkout, contract: @inventory}] =
             reasons(errors(), :undeclared_contract_dependency)
  end

  test "invoke rejects a misspelled operation in an Owned helper", ctx do
    text =
      String.replace(
        contract_source(),
        "DomainContract.invoke(nil, Stock, \"fetch\", id)",
        "ArchitectureExample.Checkout.Helper.run(id)"
      )

    text =
      text <>
        """

        defmodule ArchitectureExample.Checkout.Helper do
          use DomainContract.Owned, owner: ArchitectureExample.Checkout
          alias ArchitectureExample.Inventory, as: Stock
          def run(id), do: DomainContract.invoke(nil, Stock, "fetxh", id)
        end
        """

    compile!(ctx, text)

    assert [%{module: ArchitectureExample.Checkout.Helper, operation: "fetxh"}] =
             reasons(errors(), :unknown_contract_operation)
  end

  test "invoke validates fully literal input using the existing payload schema", ctx do
    compile!(
      ctx,
      contract_source("DomainContract.invoke(nil, Stock, \"fetch\", \"wrong\")")
      |> String.replace("def run(id)", "def run(_id)")
    )

    assert [%{operation: "fetch"}] = reasons(errors(), :invalid_contract_input)
  end

  test "unknown dynamic contract target and operation are surfaced", ctx do
    compile!(
      ctx,
      contract_source(
        "{DomainContract.invoke(nil, id, \"fetch\", 1), DomainContract.invoke(nil, Stock, id, 1)}"
      )
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dynamic)) ==
             [:contract_operation, :contract_target]
  end

  test "macro-expanded call and imported invoke retain their operation checks", ctx do
    text =
      contract_source(
        "{invoke(nil, Stock, \"missing\", id), DomainContract.call(Stock, \"fetch\", \"bad\")}"
      )
      |> inject(@checkout, "import DomainContract, only: [invoke: 4]")

    compile!(ctx, text)
    assert [%{operation: "missing"}] = reasons(errors(), :unknown_contract_operation)
    assert [%{operation: "fetch"}] = reasons(errors(), :invalid_contract_input)
  end

  test "literal apply to invoke cannot hide its contract operation", ctx do
    compile!(
      ctx,
      contract_source("apply(DomainContract, :invoke, [nil, Stock, \"missing\", id])")
    )

    assert [%{operation: "missing"}] = reasons(errors(), :unknown_contract_operation)
  end

  test "native call/3 cannot hide a literal invalid operation or payload", ctx do
    compile!(
      ctx,
      contract_source("{Stock.call(\"missing\", id, nil), Stock.call(\"fetch\", \"wrong\", nil)}")
    )

    assert [%{operation: "missing"}] = reasons(errors(), :unknown_contract_operation)
    assert [%{operation: "fetch"}] = reasons(errors(), :invalid_contract_input)
  end

  test "literal apply to native call/3 checks the same operation", ctx do
    compile!(ctx, contract_source("apply(Stock, :call, [\"missing\", id, nil])"))
    assert [%{operation: "missing"}] = reasons(errors(), :unknown_contract_operation)
  end

  test "entry adapters exempt only their exact generated constant metadata", ctx do
    adapter = ~S"""
    defmodule ArchitectureExample.Inventory.Adapter do
      def compile(_env, _artifact, _options) do
        quote do
          def __transport_metadata__, do: %{transport: :captured}
          def runtime_helper, do: System.get_env("ARCHITECTURE_TEST")
        end
      end
    end
    """

    text =
      String.replace(
        source(),
        "use DomainContract\n",
        "use DomainContract, entry: ArchitectureExample.Inventory.Adapter\n",
        global: false
      )

    compile!(ctx, adapter <> text)

    assert [%{module: @inventory, function: {:runtime_helper, 0}}] =
             reasons(errors(), :extra_public_function)
  end

  test "a matching metadata name written by application code is still a public function", ctx do
    compile!(
      ctx,
      inject(source(), @inventory, "def __transport_metadata__, do: %{transport: :captured}")
    )

    assert [%{function: {:__transport_metadata__, 0}}] = reasons(errors(), :extra_public_function)
  end

  defp contract_source(call \\ "DomainContract.invoke(nil, Stock, \"fetch\", id)") do
    text = String.replace(source(), "native: [fetch: 1],", "native: [],")

    text =
      String.replace(text, "responsibility(\"Owns inventory and its records.\")", """
      responsibility("Owns inventory and its records.")
      operation :fetch do
        input_type :integer
        output_type :opaque
      end
      """)

    text =
      String.replace(
        text,
        "def fetch(id), do: ArchitectureExample.Inventory.Helper.fetch(id)",
        "def call(\"fetch\", id, _ctx), do: {:ok, ArchitectureExample.Inventory.Helper.fetch(id)}"
      )

    text =
      String.replace(
        text,
        "metadata(%{architecture: %{uses: [Stock], native: [run: 1]}})",
        "consumes(Stock)\n metadata(%{architecture: %{native: [run: 1]}})"
      )

    String.replace(text, "Stock.fetch(id)", call)
  end

  test "malformed metadata and unknown policy fields fail closed", ctx do
    text = String.replace(source(), "uses: [Stock]", "uses: [Stock], gateways: [:everything]")
    compile!(ctx, text)
    assert [%{module: @checkout}] = reasons(errors(), :invalid_architecture)
  end

  test "Phoenix metadata and declared components are recognized by their origin", ctx do
    compile!(
      ctx,
      source() <>
        ~S"""

        defmodule ArchitectureExample.UI do
          use Phoenix.LiveComponent
          use DomainContract.UI, entry: :html
          contract do
            version 1
            responsibility "Owns sample UI."
        command :close
          end
          attr :name, :string
          def html(assigns), do: ~H[<div>Example</div>]
          def render(assigns), do: ~H[<.html name="example" />]
        def handle_command("close", %{}, socket), do: socket
        end
        """
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "HEEx nested slots preserve proven map shapes across TagEngine rebindings", ctx do
    compile!(
      ctx,
      source() <>
        ~S"""
        defmodule ArchitectureExample.Checkout.View do
          use Phoenix.Component
          def render(%{outer: %{}} = assigns) do
            ~H"<.frame><.frame><span :for={%{} = item <- [@outer]}>{item.field}</span>{@outer.field}</.frame></.frame>"
          end
          slot :inner_block
          defp frame(%{} = assigns), do: ~H"<div>{render_slot(@inner_block)}</div>"
        end
        """
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "untyped HEEx assigns and TagEngine inputs remain dynamic", ctx do
    compile!(
      ctx,
      source() <>
        ~S"""
        defmodule ArchitectureExample.Checkout.View do
          use Phoenix.Component
          def render(assigns), do: ~H"<.frame><span>{@field}</span></.frame>"
          slot :inner_block
          defp frame(%{} = assigns), do: ~H"<div>{render_slot(@inner_block)}</div>"
          def ordinary(module), do: module.field
          def rebound(%{} = assigns, module) do
            assigns = Phoenix.LiveView.TagEngine.__assigns__(assigns, :inner_block, nil)
            _ = assigns.proven
            assigns = module
            assigns.rebound
          end
        end
        """
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["assigns.field", "assigns.rebound", "module.field"]
  end

  test "verified routes metadata requires the exact macro provenance", ctx do
    compile!(
      ctx,
      inject(source(), @checkout, """
      use Phoenix.VerifiedRoutes, router: ArchitectureExample.Inventory.Router
      """) <>
        """
        defmodule ArchitectureExample.Inventory.Router do
          use Phoenix.Router
        end
        """
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok

    {:ok, beam} = DomainContract.Architecture.Beam.read(@checkout)
    definition = Enum.find(beam.definitions, &(elem(&1, 0) == {:__phoenix_verify_routes__, 1}))
    {signature, kind, meta, clauses} = definition
    assert meta[:context] == Phoenix.VerifiedRoutes
    assert DomainContract.Architecture.Beam.internal?(definition, beam)

    refute DomainContract.Architecture.Beam.internal?(
             {signature, kind, Keyword.delete(meta, :context), clauses},
             beam
           )

    [{clause_meta, args, guards, body}] = clauses

    refute DomainContract.Architecture.Beam.internal?(
             {signature, kind, meta,
              [{Keyword.delete(clause_meta, :context), args, guards, body}]},
             beam
           )

    refute DomainContract.Architecture.Beam.internal?(
             {{:__phoenix_verify_routes__, 2}, kind, meta, clauses},
             beam
           )
  end

  test "an application function named like verified routes metadata is still checked", ctx do
    compile!(
      ctx,
      inject(source(), @checkout, """
      def __phoenix_verify_routes__(_module), do: ArchitectureExample.Inventory.Helper.fetch(1)
      """)
    )

    assert [%{function: {:__phoenix_verify_routes__, 1}}] =
             reasons(errors(), :extra_public_function)

    assert [%{caller: {:__phoenix_verify_routes__, 1}, target: {@helper, :fetch, 1}}] =
             reasons(errors(), :private_reference)
  end

  test "Phoenix controller dispatch is recognized without hiding action bodies", ctx do
    compile!(
      ctx,
      source() <>
        """
        defmodule ArchitectureExample.Checkout.Controller do
          use Phoenix.Controller, formats: [:html]
          def index(conn, _params), do: ArchitectureExample.Inventory.Helper.fetch(conn)
        end
        """
    )

    assert reasons(errors(), :dynamic_dispatch) == []

    assert [%{caller: {:index, 2}, target: {@helper, :fetch, 1}}] =
             reasons(errors(), :private_reference)
  end

  test "a user controller action override is not framework dispatch", ctx do
    compile!(
      ctx,
      source() <>
        """
        defmodule ArchitectureExample.Checkout.Controller do
          use Phoenix.Controller, formats: [:html]
          def action(conn_before, _opts), do: conn_before.private
        end
        """
    )

    assert [%{caller: {:"action (overridable 2)", 2}, dispatch: "conn_before.private"}] =
             reasons(errors(), :dynamic_dispatch)
  end

  test "router connection preparation requires the exact defining framework origin", ctx do
    compile!(
      ctx,
      source() <>
        """
        defmodule ArchitectureExample.Checkout.Router do
          use Phoenix.Router
        end
        defmodule ArchitectureExample.Checkout.Impostor do
          def prepare(conn), do: conn.script_name
        end
        """
    )

    assert [
             %{
               module: ArchitectureExample.Checkout.Impostor,
               caller: {:prepare, 1},
               dispatch: "conn.script_name"
             }
           ] = reasons(errors(), :dynamic_dispatch)
  end

  test "endpoint data reads require the defining framework origin", ctx do
    compile!(
      ctx,
      source() <>
        """
        defmodule ArchitectureExample.Checkout.Endpoint do
          use Phoenix.Endpoint, otp_app: :domain_contract
        end
        defmodule ArchitectureExample.Checkout.Impostor do
          def url, do: persistent!().url
          defp persistent!, do: Application.get_env(:domain_contract, :url_module)
        end
        """
    )

    dynamics = reasons(errors(), :dynamic_dispatch)

    assert Enum.any?(
             dynamics,
             &match?(
               %{module: ArchitectureExample.Checkout.Impostor, dispatch: "persistent!().url"},
               &1
             )
           )

    refute Enum.any?(
             dynamics,
             &(&1.module == ArchitectureExample.Checkout.Endpoint and
                 &1.dispatch in [
                   "persistent!().url",
                   "persistent!().struct_url",
                   "persistent!().static_url",
                   "persistent!().static_path",
                   "persistent!().script_name",
                   "persistent!().path",
                   "persistent!().host"
                 ])
           )
  end

  test "framework callbacks are valid entry points but their bodies are still checked", ctx do
    text =
      inject(
        source(),
        @checkout,
        "@behaviour GenServer\n @impl true\n def init(value), do: {:ok, ArchitectureExample.Inventory.Helper.fetch(value)}"
      )

    compile!(ctx, text)

    assert [%{caller: {:init, 1}, target: {@helper, :fetch, 1}}] =
             reasons(errors(), :private_reference)

    assert reasons(errors(), :extra_public_function) == []
  end

  test "reading BEAM metadata does not load implementation modules", ctx do
    compile!(ctx, source())

    for module <- [@inventory, @checkout, @helper, @record] do
      :code.purge(module)
      :code.delete(module)
    end

    assert Architecture.check_application(:architecture_example, strict: true) == :ok

    for module <- [@inventory, @checkout, @helper, @record],
        do: assert(:code.is_loaded(module) == false)
  end

  test "declarations must refer to real exported signatures", ctx do
    text = String.replace(source(), "native: [fetch: 1]", "native: [fetch: 1, missing: 2]")
    compile!(ctx, text)
    assert [%{target: {@inventory, "missing", 2}}] = reasons(errors(), :missing_export)
  end

  test "missing debug info cannot make an application appear valid", ctx do
    compile!(ctx, source())
    path = Path.join(ctx.tmp_dir, "ebin/Elixir.ArchitectureExample.Checkout.beam")
    {:ok, {_, stripped}} = :beam_lib.strip(File.read!(path))
    File.write!(path, stripped)
    assert [%{module: @checkout}] = reasons(errors(), :unsupported_debug_info)
  end

  test "explicit source exclusion is directory-scoped", ctx do
    compile!(ctx, source(), [
      {"test/support/helper.ex", "defmodule ArchitectureExample.TestHelper do\nend"}
    ])

    assert [%{module: ArchitectureExample.TestHelper}] = reasons(errors(), :unowned_module)

    assert Architecture.check_application(:architecture_example,
             strict: true,
             exclude_dirs: [Path.join(ctx.tmp_dir, "test/support")]
           ) == :ok

    assert {:error, _} =
             Architecture.check_application(:architecture_example,
               strict: true,
               exclude_dirs: [Path.join(ctx.tmp_dir, "test/supp")]
             )
  end

  test "CLI runs the golden path without starting the application", ctx do
    compile!(ctx, source())

    output =
      capture_io(fn ->
        Mix.Tasks.Domain.Check.run(["--application", "architecture_example", "--strict"])
      end)

    assert output =~ "Domain architecture is valid"

    refute Enum.any?(Application.started_applications(), fn {app, _, _} ->
             app == :architecture_example
           end)
  end

  test "CLI fails on an architecture violation", ctx do
    compile!(ctx, String.replace(source(), "Stock.fetch(id)", "Stock.Helper.fetch(id)"))

    assert_raise Mix.Error, ~r/private_reference/, fn ->
      Mix.Tasks.Domain.Check.run(["--application", "architecture_example", "--strict"])
    end
  end

  test "CLI rejects mixing application checks with artifact checks" do
    assert_raise Mix.Error, ~r/cannot be combined/, fn ->
      Mix.Tasks.Domain.Check.run(["--application", "architecture_example", "contracts.json"])
    end

    assert_raise Mix.Error, ~r/require --application/, fn ->
      Mix.Tasks.Domain.Check.run(["--strict"])
    end
  end

  test "an unknown application is an error, not an empty successful check" do
    assert {:error, [%{reason: :unreadable_application}]} =
             Architecture.check_application(:missing_architecture_app)
  end

  defp source, do: File.read!(@fixture)

  defp errors do
    assert {:error, errors} = Architecture.check_application(:architecture_example, strict: true)
    errors
  end

  defp reasons(errors, reason), do: Enum.filter(errors, &(&1.reason == reason))

  defp inject(source, module, definition) do
    [before, module_source] = String.split(source, "defmodule #{inspect(module)} do", parts: 2)
    before <> "defmodule #{inspect(module)} do\n" <> definition <> "\n" <> module_source
  end

  defp compile!(ctx, source, extra_files \\ []) do
    ebin = Path.join(ctx.tmp_dir, "ebin")
    File.mkdir_p!(ebin)
    Code.prepend_path(ebin)

    files =
      for {path, content} <- [{"lib/example.ex", source} | extra_files] do
        file = Path.join(ctx.tmp_dir, path)
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, content)
        file
      end

    previous = Code.compiler_options(debug_info: true)

    modules =
      try do
        assert {:ok, modules, []} = Kernel.ParallelCompiler.compile_to_path(files, ebin)
        modules
      after
        Code.compiler_options(previous)
      end

    application = {:application, :architecture_example, [vsn: ~c"0.1.0", modules: modules]}

    File.write!(
      Path.join(ebin, "architecture_example.app"),
      :io_lib.format(~c"~tp.~n", [application])
    )

    on_exit(fn ->
      Code.delete_path(ebin)

      for module <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)
  end
end

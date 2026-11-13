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

  test "operations and consumes are the only domain entry path", ctx do
    compile!(ctx, source())
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
    assert apply(@checkout, :call, ["run", 42, nil]) == {:ok, 42}
  end

  test "direct callbacks, captures, apply and helper calls cannot bypass the runtime", ctx do
    for call <- [
          "Stock.call(\"fetch\", id, nil)",
          "apply(Stock, :call, [\"fetch\", id, nil])",
          "&Stock.call/3",
          "Stock.Helper.fetch(id)",
          "&Stock.Helper.fetch/1",
          "Stock.Record.__struct__()"
        ] do
      compile!(
        ctx,
        String.replace(source(), "DomainContract.call(Stock, :fetch, id)", "(_ = id; #{call})")
      )

      assert reasons(errors(), :private_reference) != []
      unload(ctx)
    end
  end

  test "consumer-only declarations do not create a second public API", ctx do
    text =
      source() <>
        """
        defmodule ArchitectureExample.Presentation do
          use DomainContract
          contract do
            version(1)
            responsibility("Presents inventory data through its operation.")
            consumes(ArchitectureExample.Inventory, only: [:fetch])
          end
          def render(id), do: DomainContract.call!(ArchitectureExample.Inventory, :fetch, id)
        end
        """

    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
    unload(ctx)

    compile!(
      ctx,
      String.replace(
        text,
        "DomainContract.call!(ArchitectureExample.Inventory, :fetch, id)",
        "ArchitectureExample.Inventory.call(\"fetch\", id, nil)"
      )
    )

    assert reasons(errors(), :private_reference) != []
  end

  test "ordinary private callbacks need no native dispatch permission", ctx do
    text = inject(source(), @helper, "def with_result(value, callback), do: callback.(value)")
    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "native policies are rejected during compilation" do
    for key <- [:native, :uses, :exports, :gateways] do
      name = Module.concat(__MODULE__, "Removed#{key}")

      assert_raise CompileError, ~r/architecture supports ownership only/, fn ->
        Code.compile_string("""
        defmodule #{inspect(name)} do
          use DomainContract
          contract do
            version 1
            responsibility "Must not publish a parallel API."
            metadata %{architecture: %{#{key}: []}}
          end
        end
        """)
      end
    end
  end

  test "undeclared literal domain dependencies fail compilation" do
    assert_raise CompileError, ~r/undeclared dependency/, fn ->
      Code.compile_string("""
      defmodule ArchitectureExample.Undeclared do
        use DomainContract
        contract do
          version 1
          responsibility "Missing dependency."
        end
        def call("run", id, _), do: DomainContract.call(ArchitectureExample.Inventory, :fetch, id)
      end
      """)
    end
  end

  test "extra public functions are rejected even when unused", ctx do
    compile!(ctx, inject(source(), @inventory, "def fetch(id), do: id"))
    assert [%{function: {:fetch, 1}}] = reasons(errors(), :extra_public_function)
  end

  test "internal-looking public functions are not exempt", ctx do
    compile!(ctx, inject(source(), @inventory, "def __domain_contract_backdoor__, do: :leak"))

    assert [%{function: {:__domain_contract_backdoor__, 0}}] =
             reasons(errors(), :extra_public_function)
  end

  test "dynamic domain targets are rejected", ctx do
    compile!(
      ctx,
      String.replace(source(), "DomainContract.call(Stock, :fetch, id)", "id.fetch(1)")
    )

    assert [%{caller: {:call, 3}}] = reasons(errors(), :dynamic_dispatch)
  end

  test "literal input and operation mistakes are detected", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "DomainContract.call(Stock, :fetch, id)",
        "{DomainContract.invoke(nil, Stock, :missing, id), DomainContract.invoke(nil, Stock, :fetch, :bad)}"
      )
    )

    assert [%{operation: "missing"}] = reasons(errors(), :unknown_contract_operation)
    assert [%{operation: "fetch"}] = reasons(errors(), :invalid_contract_input)
  end

  test "owned helpers inherit dependencies without publishing their functions", ctx do
    text =
      source() <>
        """
        defmodule ArchitectureExample.OutsideHelper do
          use DomainContract.Owned, owner: ArchitectureExample.Checkout
          def read(id), do: DomainContract.call(ArchitectureExample.Inventory, :fetch, id)
        end
        """

    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "a presentation contract can remain private inside its domain owner", ctx do
    view = """
    defmodule ArchitectureExample.Inventory.View do
      use Phoenix.Component
      use DomainContract.UI, entry: :render
      use DomainContract.Owned, owner: ArchitectureExample.Inventory
      contract do
        version(1)
        responsibility("Presents the inventory owned by its domain.")
        consumes(ArchitectureExample.Inventory, only: [:fetch])
      end
      attr :id, :integer, required: true
      def render(%{} = assigns) do
        %{} = assigns = assign(assigns, :value, DomainContract.call!(ArchitectureExample.Inventory, :fetch, assigns.id))
        ~H"<span>{@value}</span>"
      end
      def private_label(id), do: to_string(id)
    end
    """

    compile!(ctx, source() <> view)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
    unload(ctx)

    compile!(
      ctx,
      String.replace(
        source(),
        "DomainContract.call(Stock, :fetch, id)",
        "Stock.View.private_label(id)"
      ) <> view
    )

    assert reasons(errors(), :private_reference) != []
  end

  test "new modules must have an owner in strict mode", ctx do
    compile!(
      ctx,
      source() <> "\ndefmodule ArchitectureExample.Orphan do\ndef read, do: :ok\nend\n"
    )

    assert [%{module: ArchitectureExample.Orphan}] = reasons(errors(), :unowned_module)
  end

  defp unload(ctx) do
    {:ok, [{:application, _, properties}]} =
      :file.consult(String.to_charlist(Path.join(ctx.tmp_dir, "ebin/architecture_example.app")))

    for module <- properties[:modules] do
      :code.purge(module)
      :code.delete(module)
    end

    Code.delete_path(Path.join(ctx.tmp_dir, "ebin"))
    File.rm_rf!(Path.join(ctx.tmp_dir, "ebin"))
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
        Mix.Tasks.Domain.Check.run([
          "--application",
          "architecture_example",
          "--strict",
          "--no-compile"
        ])
      end)

    assert output =~ "Domain architecture is valid"

    refute Enum.any?(Application.started_applications(), fn {app, _, _} ->
             app == :architecture_example
           end)
  end

  test "CLI fails on an architecture violation", ctx do
    compile!(
      ctx,
      String.replace(source(), "DomainContract.call(Stock, :fetch, id)", "Stock.Helper.fetch(id)")
    )

    assert_raise Mix.Error, ~r/private_reference/, fn ->
      Mix.Tasks.Domain.Check.run([
        "--application",
        "architecture_example",
        "--strict",
        "--no-compile"
      ])
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

  test "comprehension patterns prove elements only after their generator", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", id, _context) do
          for %{nested: %{}} = item <- id do
            item.nested.field
          end
          for item <- %{a: 1} do
            item.unknown
          end
          id.outside
        end
        """
      )
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["id.outside", "item.unknown"]
  end

  test "map aliases and copies preserve nested map pattern facts", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", %{profile: %{settings: %{}}} = first = second, _context) do
          copy = second
          {left, right} = {first, copy}
          {left.profile.settings.field, right.profile.settings.field}
        end
        """
      )
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "case patterns prove the original subject only in the successful branch", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", id, _context) do
          case id do
            %{nested: %{}} = copy -> {id.nested.field, copy.nested.field}
            _ -> id.unsafe
          end
          id.after_case
        end
        """
      )
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["id.after_case", "id.unsafe"]
  end

  test "case variable patterns inherit a proven subject shape", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", %{nested: %{}} = id, _context) do
          case id do
            value -> value.nested.field
          end
        end
        """
      )
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok
  end

  test "map matches do not prove earlier reads or their right hand side", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", id, _context) do
          value = id
          _ = value.before
          %{} = value = value.result
          _ = value.proven
          value = id
          value.rebound
        end
        """
      )
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["value.before", "value.rebound", "value.result"]
  end

  test "unknown nested fields, updates and computed map keys cannot prove module reads", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", {key, id}, _context) do
          data = %{nested: %{}}
          data = %{data | nested: id}
          _ = data.nested.updated
          data = %{:nested => %{}, key => id}
          data.nested.computed
        end
        """
      )
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["data.nested.computed", "data.nested.updated"]
  end

  test "local literal map returns prove data without hiding references in their bodies", ctx do
    text =
      source()
      |> String.replace("DomainContract.call(Stock, :fetch, id)", "marks(id).nested.field")
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
      |> String.replace(
        "DomainContract.call(Stock, :fetch, id)",
        "{marks(id).field, nested_marks(id).nested.field}"
      )
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

  test "variable and wildcard struct patterns do not construct a struct", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", %module{} = record, _context) do
          %_{} = local = record
          from_case = case local do %^module{} = value -> value.id end
          from_with = with %_{} = value <- local, do: value.id
          from_for = for %_{} = value <- [local], do: value.id
          from_fn = (fn %_{} = value -> value.id end).(local)
          {module, record.id, from_case, from_with, from_for, from_fn}
        end
        """
      )
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok

    assert apply(@checkout, :call, ["run", struct(@record, id: 7), nil]) ==
             {@record, 7, 7, 7, [7], 7}
  end

  test "dynamic struct constructors stay checked on pattern right hand sides", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", id, _context) do
          %_{} = first = struct(id, [])
          case struct!(id, []) do
            %_{} = second -> {first.id, second.id}
          end
        end
        """
      )
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), &{&1.dynamic, &1.dispatch})) ==
             [{:struct, "Kernel.struct!(id, [])"}, {:struct, "Kernel.struct(id, [])"}]
  end

  test "rescue binds exception maps without proving catch or outer variables", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", err, _context) do
          try do
            raise "failure"
          rescue
            err in RuntimeError -> err.message
          catch
            :throw, err -> err.caught
          after
            _ = err.outside
          end
          err.after_try
        end
        """
      )
    )

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["err.after_try", "err.caught", "err.outside"]
  end

  test "generic rescue normalizes Erlang errors and rebindings lose their proof", ctx do
    compile!(
      ctx,
      String.replace(
        source(),
        "def call(\"run\", id, _context), do: DomainContract.call(Stock, :fetch, id)",
        """
        def call(\"run\", id, _context) do
          try do
            :erlang.error(:failure)
          rescue
            err ->
              _ = err.__struct__
              err = id
              err.rebound
          end
        end
        """
      )
    )

    assert [%{dispatch: "err.rebound"}] = reasons(errors(), :dynamic_dispatch)
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

  test "a map assertion outside expanded HEEx preserves change tracking", ctx do
    compile!(
      ctx,
      source() <>
        ~S"""
        defmodule ArchitectureExample.Checkout.HEEx do
          defmacro sigil_H(template, modifiers) do
            rendered =
              quote do
                Phoenix.Component.sigil_H(unquote(template), unquote(modifiers))
              end
              |> Macro.expand_once(__CALLER__)

            quote do
              %{} = var!(assigns)
              unquote(rendered)
            end
          end
        end
        defmodule ArchitectureExample.Checkout.View do
          use Phoenix.Component
          import Phoenix.Component, except: [sigil_H: 2]
          import ArchitectureExample.Checkout.HEEx, only: [sigil_H: 2]
          def render(assigns), do: ~H"<span>{@value}</span>"
          def nested(assigns), do: ~H"<.frame><span>{@value}</span></.frame>"
          slot :inner_block
          defp frame(assigns), do: ~H"<div>{render_slot(@inner_block)}</div>"
        end
        """
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok

    for function <- [:render, :nested] do
      unchanged =
        apply(ArchitectureExample.Checkout.View, function, [%{__changed__: %{}, value: "visible"}])

      assert unchanged.dynamic.(true) == [nil]
      refute unchanged.dynamic.(false) == [nil]

      changed =
        apply(ArchitectureExample.Checkout.View, function, [
          %{__changed__: %{value: true}, value: "visible"}
        ])

      refute changed.dynamic.(true) == [nil]
    end
  end

  test "HEEx entry guards and Phoenix assign results preserve change tracking", ctx do
    compile!(
      ctx,
      source() <>
        ~S"""
        defmodule ArchitectureExample.Checkout.View do
          use Phoenix.Component
          def guarded(assigns) when is_map(assigns) do
            assigns = assign(assigns, [])
            ~H"<span>{@value}</span>"
          end
          def assigned(assigns) do
            assigns = assign(assigns, :value, Map.fetch!(assigns, :value))
            ~H"<span>{@value}</span>"
          end
          def lazy(assigns) do
            assigns = assign_new(assigns, :value, fn -> "fallback" end)
            ~H"<span>{@value}</span>"
          end
          def updated(assigns) do
            assigns = update(assigns, :value, fn value -> value end)
            ~H"<span>{@value}</span>"
          end
        end
        """
    )

    assert Architecture.check_application(:architecture_example, strict: true) == :ok

    for function <- [:guarded, :assigned, :lazy, :updated] do
      unchanged =
        apply(ArchitectureExample.Checkout.View, function, [%{__changed__: %{}, value: "visible"}])

      assert unchanged.dynamic.(true) == [nil]
      assert unchanged.dynamic.(false) == ["visible"]

      changed =
        apply(ArchitectureExample.Checkout.View, function, [
          %{__changed__: %{value: true}, value: "visible"}
        ])

      assert changed.dynamic.(true) == ["visible"]
    end
  end

  test "empty assign/2 and overwritten nested fields cannot invent map proofs", ctx do
    compile!(
      ctx,
      source() <>
        ~S"""
        defmodule ArchitectureExample.Checkout.View do
          use Phoenix.Component
          def empty(assigns) do
            assigns = assign(assigns, [])
            ~H"<span>{@field}</span>"
          end
          def nested(%{value: %{}} = assigns, module) do
            assigns = assign(assigns, :value, module)
            assigns.value.field
          end
        end
        """
    )

    assert Phoenix.Component.assign(@inventory, []) == @inventory

    assert Enum.sort(Enum.map(reasons(errors(), :dynamic_dispatch), & &1.dispatch)) ==
             ["assigns.field", "assigns.value.field"]
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

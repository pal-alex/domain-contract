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

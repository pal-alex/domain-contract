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

    text = String.replace(text, "Stock.fetch(id)", "Stock.call(\"fetch\", id, nil)")
    compile!(ctx, text)
    assert Architecture.check_application(:architecture_example, strict: true) == :ok
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

defmodule DomainContractTest do
  use ExUnit.Case, async: false
  alias DomainContract.Artifact
  alias DomainContract.Architecture
  alias DomainContract.Compatibility
  alias DomainContract.Context
  alias DomainContract.Info
  alias DomainContract.Runtime

  defmodule Echo do
    use DomainContract

    contract do
      version(1)
      responsibility("Owns echo and its validation.")

      operation :echo do
        input_entity :request do
          field(:text, :string)
          field(:optional, :integer, optional: true)
          field(:nullable, {:nullable, :string}, optional: true)
        end

        output_type(:string)
      end
    end

    def call("echo", input, _context), do: {:ok, input[:text] || input["text"]}
  end

  defmodule Client do
    use DomainContract

    contract do
      version(1)
      responsibility("Owns an echo client.")
      consumes(Echo)
    end

    def run(input), do: DomainContract.call(Echo, :echo, input)
    def explicit(context, input), do: DomainContract.invoke(context, Echo, :echo, input)
  end

  defmodule Client.Helper do
    use DomainContract.Owned, owner: Client
    def run(input), do: DomainContract.call(Echo, :echo, input)
  end

  defmodule Stranger do
    use DomainContract

    contract do
      version(1)
      responsibility("Owns unrelated behavior.")
    end

    def run,
      do:
        DomainContract.invoke(
          Context.new(__MODULE__, :trusted, fn _, _, _, _ -> {:ok, "no"} end),
          Echo,
          :echo,
          %{text: "no"}
        )
  end

  defmodule Editor do
    use Phoenix.Component
    use DomainContract.UI, entry: :html, prop_modes: [editable?: :controlled]

    contract do
      version(1)
      responsibility("Owns editing, but not page navigation.")
      command(:close)
      emit(:changed, payload: %{id: :integer})
    end

    attr(:source, :map, required: true)
    attr(:editable?, :boolean, default: true)
    slot(:inner_block, required: true)
    def html(assigns), do: ~H"<div>{@source}</div>"
    def handle_command("close", %{}, socket), do: Map.put(socket, :closed, true)
    def changed(socket, id), do: DomainContract.UI.emit(socket, :changed, %{id: id})
  end

  defmodule Page do
    use DomainContract.UI

    contract do
      version(1)
      responsibility("Owns the active editing page.")
      consumes(Editor)
    end

    def close(id), do: DomainContract.UI.command({Editor, id}, :close, %{})
  end

  defmodule Subscriber do
    use DomainContract.UI

    contract do
      version(1)
      responsibility("Owns payment projections.")
      subscribe(Editor, :changed)
    end

    def handle_notification(Editor, "changed", payload, socket),
      do: Map.put(socket, :received, payload)
  end

  test "one inline owner and module-only dependencies retain immutable requirements" do
    assert Echo.__contract__()["module"] == Atom.to_string(Echo)
    assert [%{"module" => module, "definition" => snapshot}] = Client.__contract__()["consumes"]
    assert module == Atom.to_string(Echo)
    assert snapshot["operations"] == Echo.__contract__()["operations"]
    refute Map.has_key?(hd(Client.__contract__()["consumes"]), "version")
    refute function_exported?(DomainContract, :call, 4)
    assert Compatibility.check([Echo, Client]) == :ok
    assert {:error, [%{reason: :missing_provider}]} = Compatibility.check([Client])
    assert {:error, _} = Compatibility.check([Echo, Echo])
  end

  test "local calls preserve values, enforce dependencies and hook ownership" do
    assert Client.run(%{text: "hi"}) == {:ok, "hi"}
    assert Client.Helper.run(%{"text" => "helper"}) == {:ok, "helper"}
    assert Stranger.run() == {:error, {:invalid_contract, :undeclared_dependency}}
    assert {:error, _} = Client.run(%{text: 2})
    assert Runtime.input(Echo, :absent, %{}) == {:error, {:invalid_contract, :invalid_operation}}
  end

  test "runtime uses loaded immutable owners after build metadata changes" do
    previous = Application.get_env(:domain_contract, :metadata_paths, [])

    path =
      Path.join(System.tmp_dir!(), "runtime-contract-#{System.unique_integer([:positive])}.json")

    altered = Echo |> Info.canonical() |> Map.put("version", 73) |> Map.delete("digest")
    File.write!(path, Info.json(altered))
    Application.put_env(:domain_contract, :metadata_paths, [path])

    try do
      assert_raise ArgumentError, ~r/ambiguous/, fn -> DomainContract.Reference.resolve(Echo) end
      assert Client.run(%{text: "captured"}) == {:ok, "captured"}
    after
      Application.put_env(:domain_contract, :metadata_paths, previous)
      File.rm!(path)
    end
  end

  test "scoped runtime and explicit contexts preserve trusted state and restore binding" do
    dispatch = fn Echo, "echo", input, context ->
      assert context.source == %{user: 7, execution: "kept"}
      {:ok, input.text <> " adapted"}
    end

    context = %{
      domain_contract: Context.new(Client, "trusted-plugin", dispatch),
      source: %{user: 7, execution: "kept"}
    }

    assert Client.explicit(context, %{text: "hi"}) == {:ok, "hi adapted"}

    assert DomainContract.with_context(context, fn -> Client.run(%{text: "bound"}) end) ==
             {:ok, "bound adapted"}

    assert Context.current() == nil

    assert_raise RuntimeError, fn ->
      DomainContract.with_context(context, fn -> raise "unwind" end)
    end

    assert Context.current() == nil

    assert DomainContract.with_context(context, fn -> Client.Helper.run(%{text: "hi"}) end) ==
             {:ok, "hi adapted"}
  end

  test "successful outputs are checked and provider errors pass through" do
    for {result, expected} <- [
          {{:ok, 42}, :invalid},
          {{:error, :unavailable}, {:error, :unavailable}},
          {:bad, :invalid}
        ] do
      context = Context.new(Client, :trusted, fn _, _, _, _ -> result end)
      actual = Client.explicit(context, %{text: "hi"})

      if expected == :invalid,
        do: assert(match?({:error, {:invalid_contract, _}}, actual)),
        else: assert(actual == expected)
    end
  end

  test "omitted, nullable, alternatives and closed fields remain distinct" do
    assert :ok = Runtime.input(Echo, :echo, %{text: "x"})
    assert :ok = Runtime.input(Echo, :echo, %{text: "x", nullable: nil})
    assert {:error, _} = Runtime.input(Echo, :echo, %{text: "x", optional: nil})
    assert {:error, _} = Runtime.input(Echo, :echo, %{text: "x", foreign: true})
    assert :ok = Runtime.validate_type({:union, [:string, :integer]}, 3)
    assert {:error, _} = Runtime.validate_type({:union, [:string, :integer]}, nil)
  end

  test "directional compatibility ignores versions, additions of operations and prose" do
    original = Echo.__contract__()

    new =
      original
      |> Map.delete("digest")
      |> Map.put("version", 42)
      |> Map.put("responsibility", "Expanded prose requires review")

    assert Compatibility.satisfies(new, original) == :ok
    assert Architecture.diff([original], [new]).incompatible == []

    assert Enum.any?(
             Architecture.diff([original], [new]).compatible,
             &(&1.surface == "responsibility" and &1.review)
           )

    removed = Map.put(new, "operations", [])
    assert {:error, _} = Compatibility.satisfies(removed, original)
    assert Compatibility.satisfies(original, removed) == :ok
    assert Architecture.diff([original], [removed]).incompatible != []
  end

  test "directional enums, closed inputs and outputs, unions and recursive entities" do
    assert Compatibility.subset?(["enum", ["a"]], ["enum", ["a", "b"]])
    refute Compatibility.subset?(["enum", ["a", "b"]], ["enum", ["a"]])
    assert Compatibility.subset?("integer", "float")
    refute Compatibility.subset?("float", "integer")
    assert Compatibility.subset?("integer", ["union", ["string", "integer"]])

    old = [
      %{"name" => "x", "fields" => [%{"name" => "id", "type" => "integer", "optional" => false}]}
    ]

    optional =
      put_in(
        old,
        [Access.at(0), "fields"],
        hd(old)["fields"] ++ [%{"name" => "extra", "type" => "string", "optional" => true}]
      )

    required = put_in(optional, [Access.at(0), "fields", Access.at(1), "optional"], false)
    assert Compatibility.subset?(["entity", "x"], ["entity", "x"], old, optional)
    refute Compatibility.subset?(["entity", "x"], ["entity", "x"], old, required)
    refute Compatibility.subset?(["entity", "x"], ["entity", "x"], optional, old)
    assert Compatibility.subset?(["entity", "x"], ["open_entity", "x"], optional, old)
  end

  test "Phoenix props have a single native declaration and independent subscriptions" do
    assert Editor.__contract__()["kind"] == "ui"
    assert Enum.find(Editor.__contract__()["props"], &(&1["name"] == "source"))["required"]

    assert Enum.find(Editor.__contract__()["props"], &(&1["name"] == "editable?"))["mode"] ==
             "controlled"

    assert Subscriber.__contract__()["consumes"] == []
    assert [%{"name" => "changed"}] = Subscriber.__contract__()["subscriptions"]
    assert :ok = DomainContract.UI.validate_props(Editor, %{source: %{}, inner_block: [%{}]})
    assert {:error, _} = DomainContract.UI.validate_props(Editor, %{})
    assert {:error, _} = DomainContract.UI.validate_props(Editor, %{source: %{}, inner_block: []})

    assert {:error, _} =
             DomainContract.UI.validate_props(Editor, %{
               :source => %{},
               "source" => %{},
               :inner_block => [%{}]
             })

    required_slot =
      Editor
      |> Info.canonical()
      |> Map.update!("slots", &(&1 ++ [%{"name" => "footer", "required" => true}]))

    assert {:error, _} = Compatibility.satisfies(required_slot, Editor)
    assert {:error, _} = DomainContract.UI.validate_props(Editor, %{source: %{}, foreign: 1})
    original = Editor.__contract__()

    optional =
      Map.update!(
        Map.delete(original, "digest"),
        "props",
        &(&1 ++ [%{"name" => "added", "type" => "string", "required" => false}])
      )

    assert Compatibility.satisfies(optional, original) == :ok

    assert {:error, _} =
             Compatibility.satisfies(
               Map.update!(optional, "props", fn props ->
                 List.update_at(props, -1, &Map.put(&1, "required", true))
               end),
               original
             )
  end

  test "commands address instances, emitters do not enumerate subscribers and cleanup removes recipients" do
    DomainContract.UI.mount(%{}, Editor, "a", :context)
    DomainContract.UI.mount(%{}, Editor, "b", :context)
    DomainContract.UI.mount(%{}, Subscriber, "one", :context)
    DomainContract.UI.mount(%{}, Subscriber, "two", :context)
    assert :ok = Page.close("b")
    assert_receive {DomainContract.UI, _, {Editor, "b"}, _} = message
    assert {:halt, %{closed: true}} = DomainContract.UI.relay(message, %{})
    assert {:error, :unmounted} = Page.close("absent")
    assert {:ok, %{}} = Editor.changed(%{}, 9)

    for id <- ["one", "two"] do
      assert_receive {DomainContract.UI, _, {Subscriber, ^id}, _} = event
      assert {:halt, %{received: %{id: 9}}} = DomainContract.UI.relay(event, %{})
    end

    DomainContract.UI.unmount(Subscriber, "one")
    Editor.changed(%{}, 10)
    assert_receive {DomainContract.UI, _, {Subscriber, "two"}, _}
    refute_receive {DomainContract.UI, _, {Subscriber, "one"}, _}
    assert {:error, _} = Editor.changed(%{}, "bad")

    assert_raise ArgumentError, fn ->
      DomainContract.UI.relay(
        {DomainContract.UI, make_ref(), {Editor, "a"}, {:command, "close", %{}}},
        %{}
      )
    end
  end

  test "architecture exports ignore private code and detect explicit bypass delivery" do
    assert Architecture.diff([Echo], [Echo]) == %{
             compatible: [],
             incompatible: [],
             diagnostics: []
           }

    report = Architecture.diff([Echo], [])
    assert Architecture.render(report) =~ "Incompatible changes"
    assert Info.encode(report) == Info.encode(Architecture.diff([Echo], []))

    assert [%{reason: :contract_bypassing_delivery, severity: :error}] =
             Architecture.diagnose(
               [{"x.ex", "Phoenix.LiveView.send_update(Editor, id: 1, command: :close)"}],
               [Editor]
             )

    assert Architecture.diagnose(
             [{"x.ex", "Phoenix.LiveView.send_update(Editor, id: 1, title: \"normal\")"}],
             [Editor]
           ) == []
  end

  test "compile rejects missing contracts, invalid schemas and incomplete implementations" do
    assert_raise ArgumentError, ~r/missing contract/, fn ->
      DomainContract.Reference.resolve(MissingOwner)
    end

    assert_raise CompileError, ~r/incomplete public/, fn ->
      compile("operation :absent, input_type: :string, output_type: :string")
    end

    assert_raise RuntimeError, ~r/invalid inline contract/, fn ->
      compile("operation :absent, input_type: :invalid, output_type: :string")
    end

    assert_raise ArgumentError, ~r/exactly one contract/, fn ->
      Code.compile_string("""
      defmodule Duplicate#{System.unique_integer([:positive])} do
        use DomainContract
        contract do
          version 1
          responsibility "one"
        end
        contract do
          version 2
          responsibility "two"
        end
      end
      """)
    end
  end

  test "independent metadata compiles consumers without loading or packaging provider implementations" do
    module = Module.concat(["OfflineOwner#{System.unique_integer([:positive])}"])

    [{^module, beam}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        use DomainContract
        contract do
          version 1
          responsibility "Owns an independently compiled echo."
          operation :echo, input_type: :string, output_type: :string
        end
        def call("echo",input,_), do: {:ok,input}
      end
      """)

    assert {:ok, artifact} = Artifact.from_beam(beam)
    assert :ok = DomainContract.Implementation.check_beam(beam, [artifact])
    :code.purge(module)
    :code.delete(module)
    path = Path.join(System.tmp_dir!(), "contract-#{System.unique_integer([:positive])}.json")
    File.write!(path, Info.encode([artifact]))
    old = Application.get_env(:domain_contract, :metadata_paths, [])
    Application.put_env(:domain_contract, :metadata_paths, [path])

    on_exit(fn ->
      Application.put_env(:domain_contract, :metadata_paths, old)
      File.rm(path)
    end)

    consumer = Module.concat(["OfflineConsumer#{System.unique_integer([:positive])}"])

    compiled =
      Code.compile_string("""
      defmodule #{inspect(consumer)} do
        use DomainContract
        contract do
          version 1
          responsibility "Owns an offline consumer."
          consumes #{inspect(module)}
        end
      end
      """)

    assert [{^consumer, _}] = compiled
    assert :code.is_loaded(module) == false
    assert [%{"module" => identity}] = consumer.__contract__()["consumes"]
    assert identity == Atom.to_string(module)
    conflicting = Path.rootname(path) <> "-conflicting.json"

    File.write!(
      conflicting,
      Info.encode([artifact |> Map.delete("digest") |> Map.put("version", 2)])
    )

    on_exit(fn -> File.rm(conflicting) end)
    Application.put_env(:domain_contract, :metadata_paths, [path, conflicting])

    assert_raise ArgumentError, ~r/ambiguous contract/, fn ->
      DomainContract.Reference.resolve(module)
    end
  end

  test "compiler rejects undeclared literal calls and missing public operations" do
    for {dependencies, operation, reason} <- [
          {"", ":echo", ~r/undeclared dependency/},
          {"consumes #{inspect(Echo)}", ":missing", ~r/undeclared operations/}
        ] do
      assert_raise CompileError, reason, fn ->
        Code.compile_string("""
        defmodule MissingDependency#{System.unique_integer([:positive])} do
          use DomainContract
          contract do
            version 1
            responsibility "Owns a checked client."
            #{dependencies}
          end
          def run, do: DomainContract.call(#{inspect(Echo)},#{operation},%{text: "hello"})
        end
        """)
      end
    end
  end

  test "Boundary and Spark preserve their own options in both declaration orders" do
    for directives <- [
          "use Boundary, deps: [DomainContract], exports: [Child]\nuse DomainContract",
          "use DomainContract\nuse Boundary, deps: [DomainContract], exports: [Child]"
        ] do
      module = Module.concat(["FrameworkOwner#{System.unique_integer([:positive])}"])

      [{^module, beam}] =
        Code.compile_string("""
        defmodule #{inspect(module)} do
          #{directives}
          contract do
            version 1
            responsibility "Owns a Boundary checked domain."
          end
        end
        """)

      {:ok, {^module, [attributes: attributes]}} = :beam_lib.chunks(beam, [:attributes])
      [boundary] = Keyword.fetch!(attributes, Boundary)
      assert boundary.opts[:deps] == [DomainContract]
      assert boundary.opts[:exports] == [Child]
      assert module.spark_is() == DomainContract
      assert {:ok, _} = Artifact.from_beam(beam)
    end
  end

  test "atom enum values remain distinct from wire strings and duplicate field spellings fail" do
    assert :ok = Runtime.validate_type({:enum, [:updated]}, :updated)
    assert {:error, _} = Runtime.validate_type({:enum, [:updated]}, "updated")
    assert {:error, _} = Runtime.input(Echo, :echo, %{:text => "first", "text" => "second"})
    assert Compatibility.check([Subscriber]) == :ok
  end

  defp compile(body) do
    Code.compile_string("""
    defmodule Invalid#{System.unique_integer([:positive])} do
      use DomainContract
      contract do
        version 1
        responsibility "Owns validation."
        #{body}
      end
    end
    """)
  end
end

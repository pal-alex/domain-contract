defmodule DomainContractTest do
  alias DomainContract.Info
  alias DomainContract.Runtime
  alias Spark.Dsl.Entity
  alias Spark.Dsl.Extension
  use ExUnit.Case, async: false

  setup_all do
    # Mix disables debug info while compiling test modules. Spark captures source
    # annotations only when this compiler option is enabled.
    previous = Code.compiler_options(debug_info: true)
    on_exit(fn -> Code.compiler_options(previous) end)
    :ok
  end

  test "equivalent declarations have identical maps and JSON despite order and source" do
    first =
      compile_contract("""
      domain :sample do
        interface :capability do
          name "sample"
          version 1
          operation :z, input: :request, output: :response
          operation :a, input: :request, output: :response
        end
        entity :response do
          field :payload, :opaque, optional: true
          field :records, {:list, {:entity, :request}}
        end
        entity :request do
          field :id, :string
        end
      end
      """)

    second =
      compile_contract("""
      domain :sample do
        entity :request do
          field :id, :string
        end
        entity :response do
          field :records, {:list, {:entity, :request}}
          field :payload, :opaque, optional: true
        end
        interface :capability do
          name "sample"
          version 1
          operation :a, input: :request, output: :response
          operation :z, input: :request, output: :response
        end
      end
      """)

    assert Info.contract(first) == Info.contract(second)
    assert Info.json(first) == Info.json(second)

    assert %{format_version: 1, domain: :sample, entities: [request, response]} =
             Info.contract(first)

    assert request.name == :request
    assert [%{name: :payload, type: :opaque, optional: true}, %{name: :records}] = response.fields
    refute Info.json(first) =~ "__spark_metadata__"
    assert Jason.decode!(Info.json(first))["domain"] == "sample"
  end

  test "runtime rejects undeclared fields and invalid nested values while preserving opaque content" do
    module =
      compile_contract("""
      domain :sample do
        entity :request do
          field :id, :string
          field :requires, {:dictionary, :integer}
          field :payload, :opaque
          field :children, {:list, {:entity, :child}}, optional: true
        end
        entity :child do
          field :enabled, :boolean
        end
        interface :capability do
          name "sample"
          version 1
          operation :get, input: :request, output: :request, optional_output: true
        end
      end
      """)

    value = %{
      "id" => "one",
      "requires" => %{"owner" => 3},
      "payload" => [nil, false, %{"task_id" => "foreign"}]
    }

    assert :ok = Runtime.input(module, "get", value)
    assert :ok = Runtime.output(module, "get", value)
    assert :ok = Runtime.output(module, "get", nil)
    assert {:error, {:invalid_contract, _}} = Runtime.input(module, "get", nil)

    assert {:error, {:invalid_contract, _}} =
             Runtime.input(module, "get", Map.put(value, "task_id", "foreign"))

    assert {:error, {:invalid_contract, _}} =
             Runtime.input(module, "get", Map.put(value, "requires", %{"owner" => "3"}))

    assert {:error, {:invalid_contract, _}} =
             Runtime.input(module, "get", Map.put(value, "children", [%{"enabled" => 1}]))

    assert {:error, :invalid_operation} = Runtime.input(module, "absent", value)
  end

  test "runtime does not choose an arbitrary interface for an ambiguous operation" do
    module =
      compile_contract("""
      domain :sample do
        entity :request do
        end
        interface :capability do
          name "sample"
          version 1
          operation :get, input: :request, output: :request
        end
        interface :transport do
          name "sample"
          version 1
          operation :get, input: :request, output: :request
        end
      end
      """)

    assert {:error, :ambiguous_operation} =
             Runtime.input(module, "get", %{})
  end

  for {label, body, expected} <- [
        {"duplicate entity", "entity :item do\nend\nentity :item do\nend", "duplicate entity"},
        {"duplicate field", "entity :item do\nfield :id, :string\nfield :id, :integer\nend",
         "duplicate field"},
        {"invalid field", "entity :item do\nfield :id, :banana\nend", "invalid field type"},
        {"unknown field entity", "entity :item do\nfield :ids, {:list, {:entity, :absent}}\nend",
         "invalid field type"},
        {"invalid interface", "interface :capability do\nname \"\"\nversion 1\nend",
         "interface requires"},
        {"invalid version", "interface :capability do\nname \"sample\"\nversion 0\nend",
         "interface requires"},
        {"invalid kind", "interface \"capability\" do\nname \"sample\"\nversion 1\nend",
         "interface requires"},
        {"duplicate interface",
         "interface :capability do\nname \"sample\"\nversion 1\nend\ninterface :capability do\nname \"sample\"\nversion 2\nend",
         "duplicate interface"},
        {"duplicate operation",
         "entity :item do\nend\ninterface :capability do\nname \"sample\"\nversion 1\noperation :get, input: :item, output: :item\noperation :get, input: :item, output: :item\nend",
         "duplicate operation"},
        {"unknown input",
         "entity :item do\nend\ninterface :capability do\nname \"sample\"\nversion 1\noperation :get, input: :absent, output: :item\nend",
         "unknown entity"},
        {"unknown output",
         "entity :item do\nend\ninterface :capability do\nname \"sample\"\nversion 1\noperation :get, input: :item, output: :absent\nend",
         "unknown entity"}
      ] do
    expected_line =
      Map.fetch!(
        %{
          "duplicate entity" => 6,
          "duplicate field" => 6,
          "invalid field" => 5,
          "unknown field entity" => 5,
          "invalid interface" => 5,
          "invalid version" => 6,
          "invalid kind" => 4,
          "duplicate interface" => 8,
          "duplicate operation" => 10,
          "unknown input" => 9,
          "unknown output" => 9
        },
        label
      )

    test label <> " fails compilation with Spark source metadata" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          compile_contract("domain :sample do\n" <> unquote(body) <> "\nend")
        end

      assert error.message =~ unquote(expected)
      assert error.location != nil, inspect(error)
      assert :erl_anno.line(error.location) == unquote(expected_line)
      assert to_string(:erl_anno.file(error.location)) == "domain_contract_fixture.ex"
      assert Exception.message(error) =~ "domain_contract_fixture.ex:"
      assert hd(error.path) == :domain
    end
  end

  test "operation names are scoped to their interface" do
    contract =
      compile_contract("""
      domain :sample do
        entity :empty do
        end
        interface :capability do
          name "sample"
          version 1
          operation :get, input: :empty, output: :empty
        end
        interface :runner_transport do
          name "sample"
          version 1
          operation :get, input: :empty, output: :empty
        end
      end
      """)

    assert length(Info.contract(contract).interfaces) == 2
  end

  test "exactly one domain is required" do
    assert_raise Spark.Error.DslError, ~r/exactly one domain/, fn -> compile_contract("") end

    assert_raise Spark.Error.DslError, ~r/exactly one domain/, fn ->
      compile_contract("domain :one do\nend\ndomain :two do\nend")
    end
  end

  test "local input and output compile to the same canonical contract as named entities" do
    localized =
      compile_contract("""
      domain :sample do
        interface :capability do
          name "sample"
          version 1
          operation :read do
            description "Read an item by its identity."
            optional_output true
            input_entity :request do
              field :id, :string
            end
            output_entity :response do
              field :payload, :opaque, description: "Owned by the caller."
            end
          end
        end
      end
      """)

    flat =
      compile_contract("""
      domain :sample do
        entity :request do
          field :id, :string
        end
        entity :response do
          field :payload, :opaque, description: "Owned by the caller."
        end
        interface :capability do
          name "sample"
          version 1
          operation :read, input: :request, output: :response,
            optional_output: true, description: "Read an item by its identity."
        end
      end
      """)

    assert Info.contract(localized) == Info.contract(flat)
    assert Info.json(localized) == Info.json(flat)
    assert :ok = Runtime.input(localized, "read", %{"id" => "one"})
    assert :ok = Runtime.output(localized, "read", nil)
    assert :ok = Runtime.output(localized, "read", %{"payload" => %{"task_id" => "foreign"}})
    assert {:error, {:invalid_contract, _}} = Runtime.input(localized, "read", %{"id" => 1})
    assert {:error, {:invalid_contract, _}} = Runtime.output(localized, "read", %{"other" => 1})
  end

  test "operation and shared type fragments resolve together into one canonical model" do
    types =
      compile_fragment("""
      declarations do
        entity :item do
          field :id, :string
        end
      end
      """)

    operations =
      compile_fragment("""
      declarations do
        operation :read do
          description "Read an item."
          input_entity :request do
            field :ids, {:list, {:entity, :item}}
          end
          output :item
        end
        operation :write, input: :item, output: :item
      end
      """)

    composed =
      compile_contract("""
      domain :sample do
        interface :capability do
          name "sample"
          version 1
          operations #{inspect(operations)}
        end
        types #{inspect(types)}
      end
      """)

    flat =
      compile_contract("""
      domain :sample do
        entity :item do
          field :id, :string
        end
        entity :request do
          field :ids, {:list, {:entity, :item}}
        end
        interface :capability do
          name "sample"
          version 1
          operation :write, input: :item, output: :item
          operation :read, input: :request, output: :item, description: "Read an item."
        end
      end
      """)

    assert Info.contract(composed) == Info.contract(flat)
    assert Info.json(composed) == Info.json(flat)
    assert :ok = Runtime.input(composed, "read", %{"ids" => [%{"id" => "one"}]})
    assert {:error, {:invalid_contract, _}} = Runtime.input(composed, "read", %{"ids" => [%{}]})

    [domain] = Extension.get_entities(composed, [:contract])
    request = Enum.find(domain.entities, &(&1.name == :request))
    [field] = request.fields
    assert to_string(:erl_anno.file(Entity.anno(field))) == "domain_fragment_fixture.ex"
    assert :erl_anno.line(Entity.anno(field)) == 7
  end

  for {label, body, expected} <- [
        {"missing input", "operation :read, output: :item", "exactly one input"},
        {"missing output", "operation :read, input: :item", "exactly one output"},
        {"reference and local input",
         "operation :read do\ninput :item\noutput :item\ninput_entity :request do\nend\nend",
         "exactly one input"},
        {"two local outputs",
         "operation :read do\ninput :item\noutput_entity :one do\nend\noutput_entity :two do\nend\nend",
         "exactly one output"},
        {"duplicate local name",
         "operation :read do\noutput :item\ninput_entity :item do\nend\nend", "duplicate entity"},
        {"invalid local field",
         "operation :read do\noutput :item\ninput_entity :request do\nfield :bad, :banana\nend\nend",
         "invalid field type"},
        {"duplicate local field",
         "operation :read do\noutput :item\ninput_entity :request do\nfield :id, :string\nfield :id, :integer\nend\nend",
         "duplicate field"}
      ] do
    test label <> " in an operation fails compilation" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          compile_contract("""
          domain :sample do
            entity :item do
            end
            interface :capability do
              name "sample"
              version 1
              #{unquote(body)}
            end
          end
          """)
        end

      assert error.message =~ unquote(expected)
      assert error.location != nil
      assert to_string(:erl_anno.file(error.location)) == "domain_contract_fixture.ex"
    end
  end

  test "invalid imported fields and references keep the fragment source location" do
    for {body, expected, line} <- [
          {"operation :read, input: :absent, output: :absent", "unknown entity", 4},
          {"operation :read do\ninput_entity :request do\nfield :bad, {:entity, :absent}\nend\noutput :request\nend",
           "invalid field type", 6}
        ] do
      fragment = compile_fragment("declarations do\n#{body}\nend")

      error =
        assert_raise Spark.Error.DslError, fn ->
          compile_contract("""
          domain :sample do
            interface :capability do
              name "sample"
              version 1
              operations #{inspect(fragment)}
            end
          end
          """)
        end

      assert error.message =~ expected
      assert to_string(:erl_anno.file(error.location)) == "domain_fragment_fixture.ex"
      assert :erl_anno.line(error.location) == line
    end
  end

  test "duplicate declarations across fragments fail compilation" do
    types = compile_fragment("declarations do\nentity :item do\nend\nend")

    operation =
      compile_fragment("declarations do\noperation :read, input: :item, output: :item\nend")

    for {imports, expected} <- [
          {"types #{inspect(types)}\ntypes #{inspect(types)}", "duplicate entity"},
          {"types #{inspect(types)}\ninterface :capability do\nname \"sample\"\nversion 1\noperations #{inspect(operation)}\noperations #{inspect(operation)}\nend",
           "duplicate operation"}
        ] do
      error =
        assert_raise Spark.Error.DslError, fn ->
          compile_contract("domain :sample do\n#{imports}\nend")
        end

      assert error.message =~ expected
      assert to_string(:erl_anno.file(error.location)) == "domain_fragment_fixture.ex"
    end
  end

  test "composition rejects a missing module and the wrong declaration kind" do
    types = compile_fragment("declarations do\nentity :item do\nend\nend")

    for module <- [types, __MODULE__, DoesNotExist] do
      error =
        assert_raise Spark.Error.DslError, fn ->
          compile_contract("""
          domain :sample do
            interface :capability do
              name "sample"
              version 1
              operations #{inspect(module)}
            end
          end
          """)
        end

      assert error.message =~ "must"
      assert to_string(:erl_anno.file(error.location)) == "domain_contract_fixture.ex"
    end
  end

  test "declarations cannot be silently omitted from the canonical domain" do
    assert_raise Spark.Error.DslError, ~r/declarations belong in/, fn ->
      compile_contract("""
      domain :sample do
      end
      declarations do
        entity :hidden do
        end
      end
      """)
    end

    fragment = compile_fragment("domain :hidden do\nend")

    assert_raise Spark.Error.DslError, ~r/must contain declarations/, fn ->
      compile_contract("domain :sample do\ntypes #{inspect(fragment)}\nend")
    end
  end

  test "variants require exactly one selected body and preserve opaque results" do
    types =
      compile_fragment("""
      declarations do
        entity :event do
          field :name, {:enum, ["started", "message"]}
        end
        entity :message do
          field :body, {:variant, %{"event" => {:entity, :event}, "result" => :opaque}}
        end
      end
      """)

    module =
      compile_contract("""
      domain :sample do
        types #{inspect(types)}
        entity :batch do
          field :messages, {:list, {:entity, :message}}
        end
        interface :delivery do
          name "sample.delivery"
          version 1
          operation :receive, input: :batch, output: :batch
        end
      end
      """)

    event = %{"type" => "event", "data" => %{"name" => "started"}}
    opaque = %{"type" => "result", "data" => %{"type" => "foreign", "anything" => [nil, 1]}}
    batch = fn body -> %{"messages" => [%{"body" => body}]} end

    for body <- [event, opaque, %{"type" => "result", "data" => nil}] do
      value = batch.(body) |> Jason.encode!() |> Jason.decode!()
      assert :ok = Runtime.input(module, "receive", value)
      assert :ok = Runtime.output(module, "receive", value)
    end

    for body <- [
          %{},
          %{"type" => "event"},
          %{"data" => %{}},
          %{"type" => "unknown", "data" => %{}},
          %{"type" => :event, "data" => %{}},
          %{"type" => "event", "data" => nil},
          %{"type" => "event", "data" => %{"name" => "unknown"}},
          %{"type" => "event", "data" => %{}},
          Map.put(event, "result", %{}),
          Map.put(event, "data", %{"name" => "started", "result" => %{}})
        ] do
      assert {:error, {:invalid_contract, _}} = Runtime.input(module, "receive", batch.(body))
    end

    assert {:error, {:invalid_contract, ["receive", :input, "messages", "body", "data"]}} =
             Runtime.input(module, "receive", batch.(%{"type" => "result"}))
  end

  test "JSON scalars preserve native values and distinguish required null from absence" do
    module =
      compile_contract("""
      domain :sample do
        entity :query do
          field :value, :json_scalar
          field :filters, {:dictionary, {:list, :json_scalar}}
        end
        interface :storage do
          name "sample.storage"
          version 1
          operation :select, input: :query, output: :query
        end
      end
      """)

    scalars = [nil, true, false, 42, -3, 1.25, "null", "42", ""]

    for scalar <- scalars do
      value = %{"value" => scalar, "filters" => %{"path" => scalars}}
      assert Jason.decode!(Jason.encode!(value)) == value
      assert :ok = Runtime.input(module, "select", value)
    end

    for value <- [
          %{"filters" => %{}},
          %{"value" => [], "filters" => %{}},
          %{"value" => %{}, "filters" => %{}},
          %{"value" => :foreign, "filters" => %{}},
          %{"value" => nil, "filters" => %{"path" => [%{}]}}
        ] do
      assert {:error, {:invalid_contract, _}} = Runtime.input(module, "select", value)
    end
  end

  test "extended types export canonical v2 independently of enum and variant declaration order" do
    contract = fn values, choices ->
      compile_contract("""
      domain :sample do
        entity :value do
          field :body, {:dictionary, {:list, {:variant, #{choices}}}}
          field :state, {:enum, #{values}}
        end
      end
      """)
    end

    first = contract.(~s(["running", "queued"]), ~s(%{"b" => :json_scalar, "a" => :opaque}))
    second = contract.(~s(["queued", "running"]), ~s(%{"a" => :opaque, "b" => :json_scalar}))
    assert Info.contract(first) == Info.contract(second)
    assert Info.json(first) == Info.json(second)
    assert Info.contract(first).format_version == 2

    assert %{"format_version" => 2, "entities" => [%{"fields" => [body, state]}]} =
             Jason.decode!(Info.json(first))

    assert body["type"] ==
             ["dictionary", ["list", ["variant", %{"a" => "opaque", "b" => "json_scalar"}]]]

    assert state["type"] == ["enum", ["queued", "running"]]
  end

  for type <- [
        "{:enum, []}",
        "{:enum, [\"a\", \"a\"]}",
        "{:enum, [\" \" ]}",
        "{:enum, [:a]}",
        "{:enum, [1]}",
        "{:variant, %{}}",
        "{:variant, %{a: :string}}",
        "{:variant, %{\"\" => :string}}",
        "{:variant, %{\"a\" => {:entity, :missing}}}",
        "{:list, {:variant, %{\"a\" => {:enum, []}}}}"
      ] do
    test "invalid extended type #{type} fails compilation at its field" do
      error =
        assert_raise Spark.Error.DslError, fn ->
          compile_contract("""
          domain :sample do
            entity :value do
              field :body, #{unquote(type)}
            end
          end
          """)
        end

      assert error.message =~ "invalid field type"
      assert :erl_anno.line(error.location) == 5
      assert to_string(:erl_anno.file(error.location)) == "domain_contract_fixture.ex"
    end
  end

  defp compile_fragment(body) do
    compile_module(body, "use DomainContract.Fragment", "domain_fragment_fixture.ex")
  end

  defp compile_contract(body) do
    compile_module(body, "use DomainContract", "domain_contract_fixture.ex")
  end

  defp compile_module(body, use_statement, file) do
    module = Module.concat(__MODULE__, "Fixture#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    Code.compile_string(
      """
      defmodule #{inspect(module)} do
        #{use_statement}
        #{body}
      end
      """,
      file
    )

    module
  end
end

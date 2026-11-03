defmodule DomainContract.Compiler do
  @moduledoc false
  def capture_boundary(module) do
    callbacks = Module.get_attribute(module, :before_compile) || []

    if {Boundary.Definition, :__before_compile__} in callbacks do
      Module.put_attribute(
        module,
        :domain_contract_boundary_options,
        Module.get_attribute(module, :opts)
      )
    end
  end

  def isolate_callbacks(module) do
    callbacks = Module.get_attribute(module, :before_compile) || []
    Module.delete_attribute(module, :before_compile)

    callbacks
    |> Enum.reverse()
    |> Enum.each(fn
      {Spark.Dsl, function} ->
        Module.put_attribute(module, :before_compile, {DomainContract.Compiler.Spark, function})

      {Boundary.Definition, function} ->
        Module.put_attribute(
          module,
          :before_compile,
          {DomainContract.Compiler.Boundary, function}
        )

      callback ->
        Module.put_attribute(module, :before_compile, callback)
    end)
  end

  def prepare_operations(module) do
    state = Process.get({module, :spark, [:contract]})

    operations =
      Enum.flat_map(state.entities, fn
        %DomainContract.Operation{name: name} ->
          [to_string(name)]

        %DomainContract.DeclarationReference{kind: :operations, module: fragment} ->
          Code.ensure_compiled!(fragment)

          fragment.spark_dsl_config()
          |> Spark.Dsl.Extension.get_entities([:declarations])
          |> Enum.map(&to_string(&1.name))

        _ ->
          []
      end)

    Module.put_attribute(module, :contract_operations, Enum.sort(Enum.uniq(operations)))
  end

  defmacro __before_compile__(env) do
    artifact = Module.get_attribute(env.module, :domain_contract_base)

    artifact =
      env.module |> DomainContract.UI.compile_props(artifact) |> DomainContract.Info.normalize()

    public = DomainContract.Reference.snapshot(artifact)

    artifact =
      Map.update!(artifact, "consumes", fn references ->
        Enum.map(references, fn reference ->
          if reference["module"] == artifact["module"],
            do: Map.put(reference, "schema", DomainContract.Schemas.id(public)),
            else: reference
        end)
      end)

    DomainContract.Owned.validate(env, artifact)
    operations = Enum.map(artifact["operations"], & &1["name"])

    covered =
      (Module.get_attribute(env.module, :domain_contract_definitions) || [])
      |> Enum.flat_map(fn {definition_env, operation, guards} ->
        DomainContract.Implementation.guarded_names(definition_env, operation, guards)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    if operations != [] and operations -- covered != [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "incomplete public call/3 implementation: #{inspect(operations -- covered)}"
    end

    artifact = Map.put(artifact, "digest", DomainContract.Reference.digest(artifact))

    adapter = Module.get_attribute(env.module, :domain_contract_entry)

    platform =
      case adapter do
        nil -> nil
        {module, options} -> module.compile(env, artifact, options)
        module -> module.compile(env, artifact, [])
      end

    # Entry adapters may emit constant metadata functions. Record only those
    # exact definitions; their executable wrappers must still be inspected.
    entry_metadata = entry_metadata(platform)

    entry =
      if operations != [] do
        quote do
          @doc false
          def __contract_entry__, do: {unquote(DomainContract.Schemas.id(artifact)), &call/3}
        end
      end

    quote do
      unquote(platform)
      unquote(entry)
      Module.register_attribute(__MODULE__, :domain_contract_artifact, persist: true)
      Module.register_attribute(__MODULE__, :domain_contract_implementation, persist: true)
      Module.register_attribute(__MODULE__, :domain_contract_entry_metadata, persist: true)
      @domain_contract_entry_metadata unquote(Macro.escape(entry_metadata))
      @domain_contract_artifact unquote(Macro.escape(artifact))
      @domain_contract_implementation %{
        contracts: [unquote(artifact["module"])],
        operations: unquote(covered)
      }
      @doc false
      def __contract__, do: unquote(Macro.escape(artifact))
      @doc false
      def __domain_contracts__, do: [__contract__()]
      @doc false
      def __domain_contract_operations__, do: unquote(covered)
    end
  end

  defp entry_metadata(platform) do
    {_, definitions} =
      Macro.prewalk(platform, [], fn
        {:def, meta, [{name, _, args}, [do: body]]} = node, definitions
        when args == [] or is_atom(args) ->
          if is_atom(meta[:context]) and not is_nil(meta[:context]) and
               Macro.quoted_literal?(body),
             do: {node, [{{name, 0}, meta[:context]} | definitions]},
             else: {node, definitions}

        node, definitions ->
          {node, definitions}
      end)

    definitions
  end
end

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
    artifact = DomainContract.UI.compile_props(env.module, artifact)
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

    quote do
      Module.register_attribute(__MODULE__, :domain_contract_artifact, persist: true)
      Module.register_attribute(__MODULE__, :domain_contract_implementation, persist: true)
      @domain_contract_artifact unquote(Macro.escape(artifact))
      @domain_contract_implementation %{
        contracts: [unquote(Macro.escape(artifact))],
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
end

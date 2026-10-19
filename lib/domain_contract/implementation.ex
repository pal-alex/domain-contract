defmodule DomainContract.Implementation do
  @moduledoc """
  Verifies a provider's common `call(operation, input, context)` entry point.

  Use `contract: My.Contract` or `contracts: [My.Contract, Other.Contract]`.
  Every operation needs a public call/3 clause with a literal string head or a
  finite `operation in [...]` guard. Generic routers can use the automatically
  derived `@contract_operations` guard. No second operation declaration is needed.

  This checks entry-point coverage and signatures, not the implementation body or
  business behavior. Packaging must compare the emitted snapshots with the exact
  package declarations; runtimes validate input/output through DomainContract.
  """
  alias DomainContract.{Compatibility, Info}

  @callback call(String.t(), term(), term()) :: {:ok, term()} | {:error, term()}

  defmacro __using__(options) do
    quote do
      # Evaluate options in module-body order, after preceding attributes have
      # been assigned. Eager macro-time evaluation cannot read those attributes.
      options = unquote(options)
      sources = options[:contracts] || List.wrap(Keyword.fetch!(options, :contract))

      for source <- sources, is_atom(source) do
        Code.ensure_compiled!(source)
        # Keep a literal compile-time call so Mix tracks declaration body changes
        # even when the source module arrives through a computed attribute.
        Code.eval_quoted({{:., [], [source, :entities]}, [], [[:contract]]}, [], __ENV__)
      end

      contracts = Enum.map(sources, &DomainContract.Info.canonical/1)

      case DomainContract.Compatibility.validate(contracts) do
        :ok ->
          :ok

        {:error, errors} ->
          raise ArgumentError, "invalid implementation declarations: #{inspect(errors)}"
      end

      @behaviour DomainContract.Implementation
      Module.register_attribute(__MODULE__, :domain_contract_call_operations, accumulate: true)
      @domain_contract_snapshots contracts
      @contract_operations DomainContract.Implementation.operations(contracts)
      @on_definition {DomainContract.Implementation, :on_definition}
      @before_compile DomainContract.Implementation
    end
  end

  @doc false
  def operations(contracts) do
    contracts
    |> Enum.flat_map(&Compatibility.provided/1)
    |> Enum.flat_map(& &1["definition"]["interface"]["operations"])
    |> Enum.map(& &1["name"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  def on_definition(env, :def, :call, [operation, _, _], guards, _body) do
    names = guarded_names(env, operation, guards)
    Enum.each(names, &Module.put_attribute(env.module, :domain_contract_call_operations, &1))
  end

  def on_definition(_, _, _, _, _, _), do: :ok

  defp guarded_names(env, operation, guards) do
    if(guards == [], do: [true], else: guards)
    |> Enum.flat_map(fn guard ->
      {_, excluded, constrained?} = operation_guard(env, operation, guard)

      cond do
        is_binary(operation) -> if MapSet.member?(excluded, operation), do: [], else: [operation]
        constrained? -> MapSet.to_list(MapSet.difference(operation_universe(env), excluded))
        true -> []
      end
    end)
  end

  # Track definitely accepted and definitely rejected operation names separately.
  # Input/context predicates remain unknown. Negation swaps the two sets, so a
  # partially understood predicate cannot invent coverage for an excluded name.
  defp operation_guard(env, operation, {:in, _, [variable, values]}) do
    if same_variable?(variable, operation) do
      {values, _} = Code.eval_quoted(values, [], env)

      if is_list(values),
        do: constraint(env, Enum.filter(values, &is_binary/1)),
        else: unknown_constraint()
    else
      unknown_constraint()
    end
  end

  # Kernel.in expands into Erlang equality/boolean calls in generated definitions
  # and in some compiler versions before on_definition runs.
  defp operation_guard(env, operation, {{:., _, [:erlang, function]}, _, arguments})
       when function in [:orelse, :andalso, :not, :"=:=", :==, :"=/=", :"/="] do
    operation_guard(env, operation, {function, [], arguments})
  end

  defp operation_guard(env, operation, {equality, _, [left, right]})
       when equality in [:===, :==, :"=:="] do
    cond do
      same_variable?(left, operation) and is_binary(right) -> constraint(env, [right])
      same_variable?(right, operation) and is_binary(left) -> constraint(env, [left])
      true -> unknown_constraint()
    end
  end

  defp operation_guard(env, operation, {inequality, _, arguments})
       when inequality in [:!=, :!==, :"=/=", :"/="] do
    equality = if inequality in [:!=, :"/="], do: :==, else: :===
    operation_guard(env, operation, {:not, [], [{equality, [], arguments}]})
  end

  defp operation_guard(env, operation, {:not, _, [guard]}) do
    {accepted, excluded, constrained?} = operation_guard(env, operation, guard)
    {excluded, accepted, constrained?}
  end

  defp operation_guard(env, _, true), do: {operation_universe(env), MapSet.new(), false}
  defp operation_guard(env, _, false), do: {MapSet.new(), operation_universe(env), true}

  defp operation_guard(env, operation, {boolean, _, [left, right]})
       when boolean in [:and, :or, :andalso, :orelse] do
    {left_yes, left_no, left_constrained?} = operation_guard(env, operation, left)
    {right_yes, right_no, right_constrained?} = operation_guard(env, operation, right)
    constrained? = left_constrained? or right_constrained?

    if boolean in [:and, :andalso] do
      {MapSet.intersection(left_yes, right_yes), MapSet.union(left_no, right_no), constrained?}
    else
      {MapSet.union(left_yes, right_yes), MapSet.intersection(left_no, right_no), constrained?}
    end
  end

  defp operation_guard(_, _, _), do: unknown_constraint()

  defp unknown_constraint, do: {MapSet.new(), MapSet.new(), false}

  defp constraint(env, names) do
    accepted = MapSet.new(names)
    {accepted, MapSet.difference(operation_universe(env), accepted), true}
  end

  defp operation_universe(env),
    do: MapSet.new(Module.get_attribute(env.module, :contract_operations))

  defp same_variable?({name, _, context}, {name, _, context}), do: true
  defp same_variable?(_, _), do: false

  defmacro __before_compile__(env) do
    contracts = Module.get_attribute(env.module, :domain_contract_snapshots)

    covered =
      Module.get_attribute(env.module, :domain_contract_call_operations)
      |> Enum.uniq()
      |> Enum.sort()

    missing = operations(contracts) -- covered

    unless Module.defines?(env.module, {:call, 3}, :def) and missing == [] do
      raise CompileError,
        file: env.file,
        line: env.line,
        description:
          "incomplete DomainContract implementation; missing public call/3 operations: #{inspect(missing)}"
    end

    quote do
      Module.register_attribute(__MODULE__, :domain_contract_implementation, persist: true)

      @domain_contract_implementation %{
        contracts: unquote(Macro.escape(contracts)),
        operations: unquote(covered)
      }
      @doc false
      def __domain_contracts__, do: unquote(Macro.escape(contracts))
      @doc false
      def __domain_contract_operations__, do: unquote(covered)
    end
  end

  @doc "Checks a loaded package entry point against its exported contract declarations."
  def check(module, expected \\ nil) do
    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :call, 3),
         true <- function_exported?(module, :__domain_contracts__, 0),
         true <- function_exported?(module, :__domain_contract_operations__, 0) do
      actual = module.__domain_contracts__()

      expected =
        if is_nil(expected), do: actual, else: Enum.map(List.wrap(expected), &Info.canonical/1)

      check_metadata(actual, module.__domain_contract_operations__(), expected)
    else
      _ -> {:error, {:invalid_contract, :invalid_implementation}}
    end
  end

  @doc "Checks an exact packaged BEAM's exports and persisted conformance metadata without loading its code."
  def check_beam(beam, expected) when is_binary(beam) do
    with {:ok, {_, chunks}} <- :beam_lib.chunks(beam, [:exports, :attributes]),
         exports = Keyword.fetch!(chunks, :exports),
         true <-
           Enum.all?(
             [{:call, 3}, {:__domain_contracts__, 0}, {:__domain_contract_operations__, 0}],
             &(&1 in exports)
           ),
         [%{contracts: actual, operations: covered}] <-
           Keyword.get(Keyword.fetch!(chunks, :attributes), :domain_contract_implementation) do
      expected = Enum.map(List.wrap(expected), &Info.canonical/1)
      check_metadata(actual, covered, expected)
    else
      _ -> {:error, {:invalid_contract, :invalid_implementation}}
    end
  end

  defp check_metadata(actual, covered, expected) do
    cond do
      not valid_metadata?(actual, covered) ->
        {:error, {:invalid_contract, :invalid_implementation}}

      actual != expected ->
        {:error, {:invalid_contract, :implementation_metadata_mismatch}}

      operations(expected) -- covered != [] ->
        {:error, {:invalid_contract, :missing_operation}}

      true ->
        :ok
    end
  end

  defp valid_metadata?(contracts, operations) when is_list(contracts) and is_list(operations) do
    Compatibility.validate(contracts) == :ok and
      Enum.all?(operations, &is_binary/1)
  end

  defp valid_metadata?(_, _), do: false
end

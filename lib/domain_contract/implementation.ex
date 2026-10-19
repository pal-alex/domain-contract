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
    {options, _} = Code.eval_quoted(options, [], __CALLER__)
    sources = options[:contracts] || List.wrap(Keyword.fetch!(options, :contract))
    contracts = Enum.map(sources, &Info.canonical/1)

    case Compatibility.validate(contracts) do
      :ok ->
        :ok

      {:error, errors} ->
        raise ArgumentError, "invalid implementation declarations: #{inspect(errors)}"
    end

    operations = operations(contracts)
    # A compile-time remote call tracks declaration body changes, not only exports.
    dependencies =
      for source <- sources, is_atom(source), do: quote(do: unquote(source).entities([:contract]))

    quote do
      unquote_splicing(dependencies)
      @behaviour DomainContract.Implementation
      Module.register_attribute(__MODULE__, :domain_contract_call_operations, accumulate: true)
      @domain_contract_snapshots unquote(Macro.escape(contracts))
      @contract_operations unquote(operations)
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
    names = if is_binary(operation), do: [operation], else: guarded_names(env, operation, guards)
    Enum.each(names, &Module.put_attribute(env.module, :domain_contract_call_operations, &1))
  end

  def on_definition(_, _, _, _, _, _), do: :ok

  defp guarded_names(env, operation, guards) do
    guards
    |> Enum.flat_map(fn guard ->
      case operation_guard(env, operation, guard) do
        nil -> []
        names -> MapSet.to_list(names)
      end
    end)
  end

  defp operation_guard(env, operation, {:in, _, [variable, values]}) do
    if same_variable?(variable, operation) do
      {values, _} = Code.eval_quoted(values, [], env)
      if is_list(values), do: MapSet.new(Enum.filter(values, &is_binary/1))
    end
  end

  defp operation_guard(env, operation, {boolean, _, [left, right]}) when boolean in [:and, :or] do
    left = operation_guard(env, operation, left)
    right = operation_guard(env, operation, right)

    case {left, right} do
      {nil, right} -> right
      {left, nil} -> left
      {left, right} when boolean == :and -> MapSet.intersection(left, right)
      {left, right} -> MapSet.union(left, right)
    end
  end

  defp operation_guard(_, _, _), do: nil

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

defmodule DomainContract.Architecture.Beam do
  @moduledoc false

  # Exact compiler entries and their defining macro, never a name prefix or a
  # blanket `generated: true` exemption. User callbacks are still inspected.
  @internals %{
    DomainContract.Compiler => [
      __contract__: 0,
      __contract_entry__: 0,
      __domain_contracts__: 0,
      __domain_contract_operations__: 0
    ],
    DomainContract => [spark_is: 0],
    Spark.Dsl => [
      spark_dsl_config: 0,
      spark_is: 0,
      entities: 1,
      fetch_opt: 2,
      section_anno: 1,
      opt_anno: 2,
      opts_anno: 1,
      section_opts: 1,
      persisted: 0,
      persisted: 2,
      fetch_persisted: 1,
      __spark_placeholder__: 0,
      __verify_spark_dsl__: 1
    ],
    Phoenix.Component.Declarative => [
      __components__: 0,
      __phoenix_component_verify__: 1,
      __phoenix_macro_components__: 0
    ],
    Phoenix.LiveView => [__live__: 0],
    Phoenix.LiveComponent => [__live__: 0]
  }

  def read(module) do
    with path when is_list(path) <- :code.where_is_file(~c"#{module}.beam"),
         {:ok, binary} <- File.read(path),
         {:ok, {^module, chunks}} <-
           :beam_lib.chunks(binary, [:attributes, :exports, :compile_info, :debug_info], [
             :allow_missing_chunks
           ]) do
      file =
        case chunks[:compile_info] do
          info when is_list(info) -> if info[:source], do: to_string(info[:source])
          _ -> nil
        end

      case chunks[:debug_info] do
        {:debug_info_v1, :elixir_erl, data} ->
          case :elixir_erl.debug_info(:elixir_v1, module, data, []) do
            {:ok, %{definitions: definitions}} ->
              {:ok,
               %{
                 module: module,
                 file: file,
                 attributes: chunks[:attributes],
                 exports: chunks[:exports],
                 definitions: definitions
               }}

            _ ->
              {:error, file, :missing_debug_info}
          end

        _ ->
          {:error, file, :unsupported_debug_info}
      end
    else
      _ -> {:error, nil, :unreadable_beam}
    end
  end

  def internal?({signature, _, meta, clauses}) do
    origin = meta[:context]

    signature in Map.get(@internals, origin, []) and
      Enum.all?(clauses, fn {clause_meta, _, _, _} -> clause_meta[:context] == origin end)
  end

  def components(beam) do
    for {{:__components__, 0}, :def, meta, [{_, [], [], {:%{}, _, entries}}]} <-
          beam.definitions,
        meta[:context] == Phoenix.Component.Declarative,
        {name, _} <- entries,
        is_atom(name),
        do: {name, 1}
  end

  def callbacks(beam) do
    beam.attributes
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.reject(&(&1 == DomainContract.Implementation))
    |> Enum.flat_map(fn behaviour ->
      case Code.Typespec.fetch_callbacks(behaviour) do
        {:ok, callbacks} -> Enum.map(callbacks, &elem(&1, 0))
        :error -> []
      end
    end)
  end

  def references(beam) do
    beam.definitions
    |> Enum.reject(&internal?/1)
    |> Enum.flat_map(fn {signature, _, meta, clauses} ->
      Enum.flat_map(clauses, fn {_, args, guards, body} ->
        walk([args, guards, body], [])
      end)
      |> Enum.map(fn reference ->
        reference
        |> Map.put(:caller, signature)
        |> Map.put(:line, reference.line || meta[:line])
      end)
    end)
    |> Enum.uniq()
  end

  # A capture's AST contains a zero-argument call-shaped node. Do not also
  # count that node as /0; the capture's declared arity is the reference.
  defp walk({:&, meta, [{:/, _, [{{:., _, [module, name]}, _, []}, arity]}]}, refs)
       when is_atom(name) and is_integer(arity) do
    reference(module, name, arity, meta, :capture, refs)
  end

  defp walk({:%, meta, [module, fields]}, refs) do
    walk(fields, reference(module, :__struct__, 0, meta, :struct, refs))
  end

  defp walk({{:., _, [module, :apply]}, meta, [target, name, args]}, refs)
       when module in [:erlang, Kernel] do
    refs =
      if is_atom(name) and literal_list?(args),
        do: reference(target, name, length(args), meta, :apply, refs),
        else: dynamic(meta, :apply, refs)

    walk([target, name, args], refs)
  end

  defp walk({{:., _, [:erlang, :make_fun]}, meta, [target, name, arity]}, refs) do
    refs =
      if is_atom(name) and is_integer(arity),
        do: reference(target, name, arity, meta, :capture, refs),
        else: dynamic(meta, :capture, refs)

    walk([target, name, arity], refs)
  end

  defp walk({{:., _, [Kernel, name]}, meta, [target | args]}, refs)
       when name in [:struct, :struct!] do
    walk([target | args], reference(target, :__struct__, 0, meta, :struct, refs))
  end

  defp walk({{:., _, [module, name]}, meta, args}, refs)
       when is_atom(name) and is_list(args) do
    refs =
      if {module, name, length(args)} in [{:erlang, :apply, 2}, {Kernel, :apply, 2}],
        do: dynamic(meta, :apply, refs),
        else: reference(module, name, length(args), meta, :call, refs)

    walk([module | args], refs)
  end

  defp walk({{:., _, [function]}, meta, args}, refs) when is_list(args) do
    refs = if match?({:fn, _, _}, function), do: refs, else: dynamic(meta, :function, refs)
    walk([function | args], refs)
  end

  defp walk(tuple, refs) when is_tuple(tuple), do: walk(Tuple.to_list(tuple), refs)
  defp walk(list, refs) when is_list(list), do: Enum.reduce(list, refs, &walk/2)
  defp walk(_, refs), do: refs

  defp literal_list?(list) when is_list(list),
    do: not Enum.any?(list, &match?({:|, _, _}, &1))

  defp literal_list?(_), do: false

  defp reference(module, name, arity, meta, kind, refs) when is_atom(module) do
    [%{target: {module, name, arity}, line: meta[:line], kind: kind} | refs]
  end

  defp reference(_, _, _, meta, kind, refs), do: dynamic(meta, kind, refs)
  defp dynamic(meta, kind, refs), do: [%{dynamic: kind, line: meta[:line]} | refs]
end

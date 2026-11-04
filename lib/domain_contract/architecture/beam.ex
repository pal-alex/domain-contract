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
    Phoenix.VerifiedRoutes => [__phoenix_verify_routes__: 1],
    Phoenix.LiveView => [__live__: 0],
    Phoenix.LiveComponent => [__live__: 0]
  }

  def header(name) do
    with path when is_list(path) <- :code.where_is_file(~c"#{name}.beam"),
         {:ok, bytes} <- File.read(path),
         {:ok, {module, chunks}} <-
           :beam_lib.chunks(bytes, [:attributes, :exports, :compile_info]),
         true <- to_string(module) == to_string(name) do
      {:ok,
       %{
         module: module,
         path: to_string(path),
         file: if(chunks[:compile_info][:source], do: to_string(chunks[:compile_info][:source])),
         attributes: chunks[:attributes],
         exports: chunks[:exports],
         definitions: []
       }}
    else
      _ -> :error
    end
  end

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

  def internal?({signature, _, meta, clauses}, beam) do
    origin = meta[:context]

    adapter =
      {signature, origin} in (beam.attributes
                              |> Keyword.get(:domain_contract_entry_metadata, [])
                              |> List.flatten())

    (signature in Map.get(@internals, origin, []) or adapter) and
      Enum.all?(clauses, fn {clause_meta, _, _, _} -> clause_meta[:context] == origin end)
  end

  def public_exports(beam) do
    macros =
      for {{name, arity}, :defmacro, _, _} <- beam.definitions,
          Enum.any?(beam.exports, fn {export, count} ->
            Atom.to_string(export) == "MACRO-" <> Atom.to_string(name) and count == arity + 1
          end),
          do: {name, arity}

    beam.exports ++ macros
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
    returns = DomainContract.Architecture.MapAccess.literal_returns(beam.definitions)

    beam.definitions
    |> Enum.reject(&internal?(&1, beam))
    |> Enum.flat_map(fn {signature, _, meta, clauses} ->
      Enum.flat_map(clauses, fn {clause_meta, args, guards, body} ->
        body = DomainContract.Architecture.MapAccess.annotate(body, args, guards, returns)

        walk([args, guards, body], [])
        |> Enum.reject(fn reference ->
          meta[:context] == clause_meta[:context] and
            framework_reference?(reference, signature, meta[:context], beam.module)
        end)
      end)
      |> Enum.map(fn reference ->
        reference
        |> Map.put(:caller, signature)
        |> Map.put(:line, reference.line || meta[:line])
      end)
    end)
    |> Enum.uniq()
  end

  # These expressions belong to the framework's own implementation, identified
  # by the defining macro on both the definition and clause. Never skip its
  # whole body: expanded application calls and user overrides still need checks.
  defp framework_reference?(
         %{dynamic: :call, dispatch: dispatch},
         {name, arity},
         Phoenix.Endpoint,
         _module
       )
       when {name, arity} in [
              url: 0,
              struct_url: 0,
              static_url: 0,
              static_path: 1,
              script_name: 0,
              path: 1,
              host: 0
            ] do
    dispatch == "persistent!().#{name}"
  end

  defp framework_reference?(
         %{dynamic: :call, dispatch: dispatch},
         {:action, 2},
         Phoenix.Controller.Pipeline,
         _module
       ) do
    dispatch in ["conn_before.private", "conn_before.private.phoenix_action"]
  end

  defp framework_reference?(
         %{dynamic: :apply, dispatch: dispatch},
         {:"action (overridable 2)", 2},
         Phoenix.Controller.Pipeline,
         module
       ) do
    dispatch == ":erlang.apply(#{inspect(module)}, action, [conn, conn.params])"
  end

  defp framework_reference?(
         %{dynamic: :call, dispatch: "conn.script_name"},
         {:prepare, 1},
         Phoenix.Router,
         _module
       ),
       do: true

  defp framework_reference?(_, _, _, _), do: false

  # A capture's AST contains a zero-argument call-shaped node. Do not also
  # count that node as /0; the capture's declared arity is the reference.
  defp walk({:&, meta, [{:/, _, [{{:., _, [module, name]}, _, []}, arity]}]} = node, refs)
       when is_atom(name) and is_integer(arity) do
    reference(module, name, arity, meta, :capture, refs, node)
  end

  defp walk({:%, meta, [module, fields]} = node, refs) do
    walk(fields, reference(module, :__struct__, 0, meta, :struct, refs, node))
  end

  # An explicit-context call is a runtime function, so the compiler's macro
  # validation cannot see it. The expanded AST still carries its actual target
  # and operation, including aliases and imported invoke/4 calls.
  defp walk(
         {{:., _, [DomainContract, :invoke]}, meta, [context, target, operation, input]} = node,
         refs
       ) do
    walk(
      [context, target, operation, input],
      contract(target, operation, input, meta, refs, node)
    )
  end

  defp walk(
         {{:., _, [DomainContract.Runtime, :invoke]}, meta,
          [owner, target, operation, input, context]} = node,
         refs
       ) do
    walk(
      [owner, context, target, operation, input],
      contract(target, operation, input, meta, refs, node)
    )
  end

  defp walk({{:., _, [module, :apply]}, meta, [target, name, args]} = node, refs)
       when module in [:erlang, Kernel] do
    refs =
      if is_atom(name) and literal_list?(args),
        do: reference(target, name, length(args), meta, :apply, refs, node),
        else: dynamic(meta, :apply, refs, node)

    refs =
      case {target, name, args} do
        {target, :call, [operation, input, _context]} when is_atom(target) ->
          [ref | rest] = refs
          [Map.put(ref, :operation_call, {operation, input}) | rest]

        {DomainContract, :invoke, [_context, target, operation, input]} ->
          contract(target, operation, input, meta, refs, node)

        {DomainContract.Runtime, :invoke, [_owner, target, operation, input, _context]} ->
          contract(target, operation, input, meta, refs, node)

        _ ->
          refs
      end

    walk([target, name, args], refs)
  end

  defp walk({{:., _, [:erlang, :make_fun]}, meta, [target, name, arity]} = node, refs) do
    refs =
      if is_atom(name) and is_integer(arity),
        do: reference(target, name, arity, meta, :capture, refs, node),
        else: dynamic(meta, :capture, refs, node)

    walk([target, name, arity], refs)
  end

  defp walk({{:., _, [Kernel, name]}, meta, [target | args]} = node, refs)
       when name in [:struct, :struct!] do
    walk([target | args], reference(target, :__struct__, 0, meta, :struct, refs, node))
  end

  defp walk({{:., _, [module, :call]}, meta, [operation, input, context]} = node, refs)
       when is_atom(module) do
    [ref | refs] = reference(module, :call, 3, meta, :call, refs, node)
    ref = Map.put(ref, :operation_call, {operation, input})
    walk([operation, input, context], [ref | refs])
  end

  defp walk({{:., _, [module, name]}, meta, args} = node, refs)
       when is_atom(name) and is_list(args) do
    refs =
      cond do
        meta[:domain_contract_map_access] ->
          refs

        {module, name, length(args)} in [{:erlang, :apply, 2}, {Kernel, :apply, 2}] ->
          dynamic(meta, :apply, refs, node)

        true ->
          reference(module, name, length(args), meta, :call, refs, node)
      end

    walk([module | args], refs)
  end

  defp walk({{:., _, [function]}, meta, args} = node, refs) when is_list(args) do
    refs =
      if match?({kind, _, _} when kind in [:fn, :&], function),
        do: refs,
        else: dynamic(meta, :function, refs, node)

    walk([function | args], refs)
  end

  defp walk(tuple, refs) when is_tuple(tuple), do: walk(Tuple.to_list(tuple), refs)
  defp walk(list, refs) when is_list(list), do: Enum.reduce(list, refs, &walk/2)
  defp walk(_, refs), do: refs

  defp literal_list?(list) when is_list(list),
    do: not Enum.any?(list, &match?({:|, _, _}, &1))

  defp literal_list?(_), do: false

  defp contract(target, operation, input, meta, refs, node)
       when is_atom(target) and not is_nil(target) do
    reference = %{
      contract: target,
      operation: operation,
      input: input,
      line: meta[:line],
      dispatch: Macro.to_string(node)
    }

    [reference | refs]
  end

  defp contract(_, _, _, meta, refs, node), do: dynamic(meta, :contract_target, refs, node)

  defp reference(module, name, arity, meta, kind, refs, _node) when is_atom(module) do
    [%{target: {module, name, arity}, line: meta[:line], kind: kind} | refs]
  end

  defp reference(_, _, _, meta, kind, refs, node), do: dynamic(meta, kind, refs, node)

  defp dynamic(meta, kind, refs, node),
    do: [%{dynamic: kind, line: meta[:line], dispatch: Macro.to_string(node)} | refs]
end

defmodule DomainContract.Architecture.Checker do
  @moduledoc false
  alias DomainContract.Architecture.Beam

  def check_application(application, opts) do
    with :ok <- options(opts),
         {:ok, modules} <- modules(application) do
      excluded = Enum.map(Keyword.get(opts, :exclude_dirs, []), &Path.expand/1)

      {beams, errors} =
        Enum.reduce(modules, {%{}, []}, fn module, {beams, errors} ->
          case Beam.read(module) do
            {:ok, beam} ->
              if excluded?(beam.file, excluded),
                do: {beams, errors},
                else: {Map.put(beams, module, beam), errors}

            {:error, file, reason} ->
              if excluded?(file, excluded),
                do: {beams, errors},
                else: {beams, [diagnostic(module, file, reason) | errors]}
          end
        end)

      {policies, errors} = policies(beams, errors)
      {claims, errors} = claims(policies, errors)

      {owners, errors} =
        owners(beams, policies, claims, Keyword.get(opts, :strict, false), errors)

      errors =
        errors ++
          declarations(beams, policies, owners) ++
          surfaces(beams, policies) ++ references(beams, policies, owners, claims)

      case errors |> Enum.uniq() |> Enum.sort() do
        [] -> :ok
        errors -> {:error, errors}
      end
    end
  end

  defp options(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:strict, :exclude_dirs] == [] and
         is_boolean(Keyword.get(opts, :strict, false)) and
         is_list(Keyword.get(opts, :exclude_dirs, [])) and
         Enum.all?(Keyword.get(opts, :exclude_dirs, []), &is_binary/1),
       do: :ok,
       else: {:error, [%{severity: :error, reason: :invalid_options}]}
  end

  # The .app resource is the build's module inventory. Reading it does not load
  # implementation modules or start the application (including its dependencies).
  defp modules(application) when is_atom(application) do
    with path when is_list(path) <- :code.where_is_file(~c"#{application}.app"),
         {:ok, [{:application, ^application, properties}]} <- :file.consult(path),
         modules when is_list(modules) <- properties[:modules],
         true <- Enum.all?(modules, &is_atom/1) do
      {:ok, Enum.sort(Enum.uniq(modules))}
    else
      _ ->
        {:error, [%{severity: :error, reason: :unreadable_application, application: application}]}
    end
  end

  defp modules(application),
    do: {:error, [%{severity: :error, reason: :invalid_application, application: application}]}

  defp excluded?(nil, _), do: false

  defp excluded?(file, dirs) do
    path = Path.expand(file)
    Enum.any?(dirs, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  defp policies(beams, errors) do
    Enum.reduce(beams, {%{}, errors}, fn {module, beam}, {policies, errors} ->
      case Keyword.get(beam.attributes, :domain_contract_artifact) do
        nil ->
          {policies, errors}

        [artifact] when is_map(artifact) ->
          with :ok <- DomainContract.Artifact.validate(artifact),
               true <- artifact["module"] == Atom.to_string(module),
               {:ok, policy} <- policy(artifact, module) do
            {Map.put(policies, module, policy), errors}
          else
            _ -> {policies, [diagnostic(module, beam.file, :invalid_architecture) | errors]}
          end

        _ ->
          {policies, [diagnostic(module, beam.file, :invalid_architecture) | errors]}
      end
    end)
  end

  defp policy(artifact, module) do
    architecture = Map.get(artifact["metadata"], "architecture", %{})

    with true <- is_map(architecture),
         true <- Map.keys(architecture) -- ~w(owns uses native exports) == [],
         {:ok, owns} <- module_names(Map.get(architecture, "owns", [])),
         {:ok, uses} <- module_names(Map.get(architecture, "uses", [])),
         {:ok, native} <- signatures(Map.get(architecture, "native", [])),
         {:ok, exports} <- exports(Map.get(architecture, "exports", %{})) do
      {:ok,
       %{
         owns: Enum.uniq([Atom.to_string(module) | owns]),
         uses: Enum.uniq(uses ++ Enum.map(artifact["consumes"], & &1["module"])),
         native: native ++ if(artifact["operations"] == [], do: [], else: [{"call", 3}]),
         callbacks: ui_callbacks(artifact),
         exports: exports
       }}
    else
      _ -> :error
    end
  end

  defp ui_callbacks(%{"kind" => "ui"} = artifact) do
    if(artifact["commands"] == [], do: [], else: [handle_command: 3]) ++
      if(artifact["subscriptions"] == [], do: [], else: [handle_notification: 4])
  end

  defp ui_callbacks(_), do: []

  defp module_names(names) when is_list(names) do
    if Enum.all?(names, &module_name?/1), do: {:ok, names}, else: :error
  end

  defp module_names(_), do: :error
  defp module_name?(name) when is_binary(name), do: String.starts_with?(name, "Elixir.")
  defp module_name?(_), do: false

  # Info canonicalizes a keyword list as [["name", arity], ...]. There is one
  # signature representation, so duplicate names with different arities survive.
  defp signatures(signatures) when is_list(signatures) do
    if Enum.all?(signatures, fn
         [name, arity] -> is_binary(name) and name != "" and is_integer(arity) and arity in 0..255
         _ -> false
       end),
       do: {:ok, Enum.map(signatures, fn [name, arity] -> {name, arity} end)},
       else: :error
  end

  defp signatures(_), do: :error

  defp exports(exports) when is_map(exports) do
    Enum.reduce_while(exports, {:ok, %{}}, fn {module, signatures}, {:ok, result} ->
      case {module_name?(module), signatures(signatures)} do
        {true, {:ok, signatures}} -> {:cont, {:ok, Map.put(result, module, signatures)}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp exports(_), do: :error

  defp claims(policies, errors) do
    claims =
      for {owner, policy} <- policies, prefix <- policy.owns, reduce: %{} do
        claims -> Map.update(claims, prefix, [owner], &[owner | &1])
      end

    errors =
      for {prefix, owners} <- claims, length(owners) > 1, reduce: errors do
        errors ->
          [
            %{
              severity: :error,
              reason: :conflicting_ownership,
              prefix: prefix,
              owners: Enum.sort(owners)
            }
            | errors
          ]
      end

    {Enum.sort_by(claims, fn {prefix, _} -> {-String.length(prefix), prefix} end), errors}
  end

  defp namespace_owner(module, claims) do
    name = Atom.to_string(module)

    case Enum.find(claims, fn {prefix, _} ->
           name == prefix or String.starts_with?(name, prefix <> ".")
         end) do
      {_, [owner]} -> owner
      _ -> nil
    end
  end

  defp owners(beams, policies, claims, strict, errors) do
    Enum.reduce(beams, {%{}, errors}, fn {module, beam}, {owners, errors} ->
      namespace = namespace_owner(module, claims)
      annotation = Keyword.get(beam.attributes, :domain_contract_owner_metadata, [])

      {owner, reason} =
        case annotation do
          [] ->
            {namespace, nil}

          [owner] when is_atom(owner) ->
            cond do
              not Map.has_key?(policies, owner) -> {nil, :unknown_owner}
              namespace != nil and namespace != owner -> {nil, :conflicting_ownership}
              true -> {owner, nil}
            end

          _ ->
            {nil, :invalid_owner}
        end

      reason = reason || if(strict and is_nil(owner), do: :unowned_module)
      errors = if reason, do: [diagnostic(module, beam.file, reason) | errors], else: errors
      {Map.put(owners, module, owner), errors}
    end)
  end

  defp declarations(beams, policies, owners) do
    by_name = Map.new(beams, fn {module, beam} -> {Atom.to_string(module), beam} end)

    Enum.flat_map(policies, fn {owner, policy} ->
      beam = beams[owner]

      dependencies =
        for dependency <- policy.uses,
            not Enum.any?(Map.keys(policies), &(Atom.to_string(&1) == dependency)),
            do: diagnostic(owner, beam.file, :unknown_dependency, %{dependency: dependency})

      exports =
        Enum.flat_map(policy.exports, fn {name, signatures} ->
          case by_name[name] do
            nil ->
              [diagnostic(owner, beam.file, :unknown_export, %{target: name})]

            target ->
              if owners[target.module] == owner,
                do: missing_exports(owner, target, signatures),
                else: [diagnostic(owner, beam.file, :foreign_export, %{target: target.module})]
          end
        end)

      dependencies ++ missing_exports(owner, beam, policy.native) ++ exports
    end)
  end

  defp missing_exports(owner, beam, signatures) do
    actual = Enum.map(beam.exports, &signature/1)

    for signature <- signatures -- actual,
        do:
          diagnostic(owner, beam.file, :missing_export, %{
            target: {beam.module, elem(signature, 0), elem(signature, 1)}
          })
  end

  defp surfaces(beams, policies) do
    Enum.flat_map(policies, fn {module, policy} ->
      beam = beams[module]
      framework = Beam.callbacks(beam) ++ Beam.components(beam) ++ policy.callbacks

      for {mfa, kind, meta, _} = definition <- beam.definitions,
          kind in [:def, :defmacro],
          not Beam.internal?(definition),
          mfa not in framework,
          signature(mfa) not in policy.native,
          do:
            diagnostic(module, beam.file, :extra_public_function, %{
              function: mfa,
              line: meta[:line]
            })
    end)
  end

  defp references(beams, policies, owners, claims) do
    Enum.flat_map(beams, fn {module, beam} ->
      Enum.flat_map(Beam.references(beam), fn reference ->
        details = Map.merge(reference, %{owner: owners[module]})

        case reference do
          %{dynamic: _} ->
            [diagnostic(module, beam.file, :dynamic_dispatch, details)]

          %{target: {target, name, arity}} ->
            target_owner = Map.get(owners, target) || namespace_owner(target, claims)

            cond do
              not Map.has_key?(beams, target) and :code.which(target) == :non_existing ->
                [diagnostic(module, beam.file, :unresolved_module, details)]

              is_nil(target_owner) ->
                []

              owners[module] == target_owner ->
                []

              true ->
                policy = policies[owners[module]]
                declared? = policy && Atom.to_string(target_owner) in policy.uses

                exported? =
                  exported?(beams[target], policies[target_owner], target_owner, name, arity)

                for {reason, valid?} <- [
                      undeclared_dependency: declared?,
                      private_reference: exported?
                    ],
                    valid? != true,
                    do:
                      diagnostic(
                        module,
                        beam.file,
                        reason,
                        Map.put(details, :target_owner, target_owner)
                      )
            end
        end
      end)
    end)
  end

  defp exported?(nil, _, _, _, _), do: false

  defp exported?(beam, policy, owner, name, arity) do
    signatures =
      if beam.module == owner,
        do: policy.native ++ Enum.map(Beam.components(beam), &signature/1),
        else: Map.get(policy.exports, Atom.to_string(beam.module), [])

    {name, arity} in beam.exports and {Atom.to_string(name), arity} in signatures
  end

  defp signature({name, arity}), do: {Atom.to_string(name), arity}

  defp diagnostic(module, file, reason, details \\ %{}),
    do: Map.merge(%{severity: :error, module: module, file: file, reason: reason}, details)
end

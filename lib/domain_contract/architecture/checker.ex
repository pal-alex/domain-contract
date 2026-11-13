defmodule DomainContract.Architecture.Checker do
  @moduledoc false
  alias DomainContract.Architecture.Beam
  alias DomainContract.Architecture.Catalog

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

      checked = Map.keys(beams)
      references = Map.new(beams, fn {module, beam} -> {module, Beam.references(beam)} end)
      beams = Catalog.extend(beams, references)
      {policies, errors} = policies(beams, errors)
      {claims, errors} = claims(policies, errors)

      {owners, errors} =
        owners(
          beams,
          policies,
          claims,
          MapSet.new(if(Keyword.get(opts, :strict, false), do: checked, else: [])),
          errors
        )

      errors =
        errors ++
          declarations(beams, policies, checked) ++
          surfaces(beams, Map.take(policies, checked)) ++
          references(beams, policies, owners, claims, references)

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
               {:ok, policy} <- policy(artifact, module),
               {:ok, policy} <- private_ui_owner(policy, beam) do
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
         true <- Map.keys(architecture) -- ["owns"] == [],
         {:ok, owns} <- module_names(Map.get(architecture, "owns", [])) do
      {:ok,
       %{
         contract: artifact,
         owns: Enum.uniq([Atom.to_string(module) | owns]),
         dependencies: Enum.map(artifact["consumes"], & &1["module"]),
         callbacks: ui_callbacks(artifact),
         provider?: artifact["operations"] != [] or artifact["kind"] == "ui"
       }}
    else
      _ -> :error
    end
  end

  defp private_ui_owner(policy, beam) do
    case Keyword.get(beam.attributes, :domain_contract_owner_metadata, []) do
      [] ->
        {:ok, Map.put(policy, :private_owner, nil)}

      [owner] when is_atom(owner) ->
        if policy.contract["kind"] == "ui" and policy.contract["operations"] == [],
          do: {:ok, Map.put(policy, :private_owner, owner)},
          else: :error

      _ ->
        :error
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

  defp claims(policies, errors) do
    claims =
      for {owner, policy} <- policies, prefix <- policy.owns, reduce: %{} do
        claims ->
          owner = policy.private_owner || owner
          Map.update(claims, prefix, [owner], &Enum.uniq([owner | &1]))
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
            owner = if policies[owner], do: policies[owner].private_owner || owner, else: owner

            cond do
              not Map.has_key?(policies, owner) -> {nil, :unknown_owner}
              namespace != nil and namespace != owner -> {nil, :conflicting_ownership}
              true -> {owner, nil}
            end

          _ ->
            {nil, :invalid_owner}
        end

      reason = reason || if(MapSet.member?(strict, module) and is_nil(owner), do: :unowned_module)
      errors = if reason, do: [diagnostic(module, beam.file, reason) | errors], else: errors
      {Map.put(owners, module, owner), errors}
    end)
  end

  # A consumed owner may be represented only by immutable metadata (for example,
  # a plugin built without loading another plugin). Compilation validated it;
  # presence of its implementation is an installation concern.
  defp declarations(_beams, _policies, _checked), do: []

  defp surfaces(beams, policies) do
    policies
    |> Enum.filter(fn {_, policy} -> policy.provider? and is_nil(policy.private_owner) end)
    |> Enum.flat_map(fn {module, policy} ->
      beam = beams[module]
      framework = Beam.callbacks(beam) ++ Beam.components(beam) ++ policy.callbacks

      for {mfa, kind, meta, _} = definition <- beam.definitions,
          kind in [:def, :defmacro],
          not Beam.internal?(definition, beam),
          mfa not in framework,
          mfa != {:call, 3},
          do:
            diagnostic(module, beam.file, :extra_public_function, %{
              function: mfa,
              line: meta[:line]
            })
    end)
  end

  defp references(beams, policies, owners, claims, references) do
    Enum.flat_map(references, fn {module, refs} ->
      beam = beams[module]

      refs
      |> Enum.flat_map(fn reference ->
        details = reference |> Map.delete(:operation_call) |> Map.put(:owner, owners[module])

        case reference do
          %{contract: target, operation: operation, input: input} ->
            contract_reference(
              module,
              beam,
              lexical_policy(module, beam, policies, owners[module]),
              target,
              operation,
              input,
              Map.drop(details, [:input, :operation]),
              policies[target]
            )

          %{dynamic: _} ->
            if policies[owners[module]] && policies[owners[module]].provider?,
              do: [diagnostic(module, beam.file, :dynamic_dispatch, details)],
              else: []

          %{target: {target, name, arity}} ->
            target_owner = Map.get(owners, target) || namespace_owner(target, claims)

            cond do
              not Map.has_key?(beams, target) and :code.which(target) == :non_existing ->
                [diagnostic(module, beam.file, :unresolved_module, details)]

              is_nil(target_owner) or not policies[target_owner].provider? ->
                []

              owners[module] == target_owner ->
                []

              true ->
                policy = lexical_policy(module, beam, policies, owners[module])

                declared? =
                  policy &&
                    Enum.any?(
                      [target, target_owner],
                      &(Atom.to_string(&1) in policy.dependencies)
                    )

                exported? =
                  exported?(beams[target], policies[target], target, name, arity)

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

  defp lexical_policy(module, beam, policies, fallback) do
    explicit = Keyword.get(beam.attributes, :domain_contract_owner_metadata, [])

    candidate =
      case explicit do
        [owner] -> policies[owner]
        [] -> nil
      end

    policies[module] || candidate ||
      policies
      |> Enum.filter(fn {_owner, policy} ->
        Enum.any?(policy.owns, fn prefix ->
          Atom.to_string(module) == prefix or
            String.starts_with?(Atom.to_string(module), prefix <> ".")
        end)
      end)
      |> Enum.max_by(fn {owner, _} -> String.length(Atom.to_string(owner)) end, fn ->
        {nil, policies[fallback]}
      end)
      |> elem(1)
  end

  defp contract_reference(
         module,
         beam,
         policy,
         target,
         operation,
         input,
         details,
         target_policy
       ) do
    reference =
      policy && Enum.find(policy.contract["consumes"], &(&1["module"] == Atom.to_string(target)))

    cond do
      is_nil(reference) ->
        [diagnostic(module, beam.file, :undeclared_contract_dependency, details)]

      not (is_binary(operation) or (is_atom(operation) and not is_nil(operation))) ->
        [
          diagnostic(
            module,
            beam.file,
            :dynamic_dispatch,
            Map.put(details, :dynamic, :contract_operation)
          )
        ]

      true ->
        schema =
          cond do
            reference -> DomainContract.Reference.definition(reference, policy.contract)
            target_policy -> target_policy.contract
            true -> nil
          end

        if schema && (is_binary(operation) or (is_atom(operation) and not is_nil(operation))) do
          contract_input(module, beam, schema, operation, input, details)
        else
          []
        end
    end
  end

  defp contract_input(module, beam, schema, operation, input, details) do
    details = Map.put(details, :operation, to_string(operation))

    if Enum.any?(schema["operations"], &(&1["name"] == to_string(operation))) do
      case literal(input) do
        {:ok, value} ->
          case DomainContract.Runtime.input(schema, operation, value) do
            :ok ->
              []

            {:error, error} ->
              [
                diagnostic(
                  module,
                  beam.file,
                  :invalid_contract_input,
                  Map.put(details, :error, error)
                )
              ]
          end

        :dynamic ->
          []
      end
    else
      [diagnostic(module, beam.file, :unknown_contract_operation, details)]
    end
  end

  # Decode data only; checking a build must never evaluate application code.
  defp literal({:%{}, _, fields}) do
    case literal(fields) do
      {:ok, fields} -> {:ok, Map.new(fields)}
      :dynamic -> :dynamic
    end
  end

  defp literal({:{}, _, fields}) do
    case literal(fields) do
      {:ok, fields} -> {:ok, List.to_tuple(fields)}
      :dynamic -> :dynamic
    end
  end

  defp literal({left, right}) do
    with {:ok, left} <- literal(left), {:ok, right} <- literal(right), do: {:ok, {left, right}}
  end

  defp literal(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, values} ->
      case literal(item) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        :dynamic -> {:halt, :dynamic}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :dynamic -> :dynamic
    end
  end

  defp literal(value) when is_atom(value) or is_binary(value) or is_number(value),
    do: {:ok, value}

  defp literal(_), do: :dynamic

  # Only Phoenix function component entries cross owners directly. Domain and UI
  # message callbacks are invoked by their validating runtime, never by consumers.
  defp exported?(nil, _, _, _, _), do: false

  defp exported?(beam, %{contract: %{"kind" => "ui"}}, owner, name, arity),
    do: beam.module == owner and {name, arity} in Beam.components(beam)

  defp exported?(_, _, _, _, _), do: false

  defp diagnostic(module, file, reason, details \\ %{}),
    do: Map.merge(%{severity: :error, module: module, file: file, reason: reason}, details)
end

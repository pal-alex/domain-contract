defmodule DomainContract.Architecture do
  @moduledoc "Deterministic public architecture export and directional review reports."
  alias DomainContract.Compatibility
  alias DomainContract.Info

  def export(contracts),
    do: contracts |> Enum.map(&Info.canonical/1) |> Enum.sort_by(& &1["module"])

  def diff(before, after_state, diagnostics \\ []) do
    before = Map.new(export(before), &{&1["module"], &1})
    after_state = Map.new(export(after_state), &{&1["module"], &1})

    changes =
      (Map.keys(before) ++ Map.keys(after_state))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn module ->
        case {before[module], after_state[module]} do
          {nil, _} -> [%{module: module, surface: "module", change: :added, compatible: true}]
          {_, nil} -> [%{module: module, surface: "module", change: :removed, compatible: false}]
          {old, new} -> compare(module, old, new)
        end
      end)

    %{
      compatible: Enum.filter(changes, & &1.compatible),
      incompatible: Enum.reject(changes, & &1.compatible),
      diagnostics: Enum.sort_by(diagnostics, &Info.encode/1)
    }
  end

  defp compare(module, old, new) do
    compatibility = Compatibility.satisfies(new, old)

    errors =
      case compatibility do
        :ok -> []
        {:error, errors} -> errors
      end

    changes =
      for key <-
            ~w(operations props slots commands notifications consumes subscriptions responsibility description metadata version),
          old[key] != new[key] do
        breaking = Enum.any?(errors, &(to_string(Map.get(&1, :surface, "")) == key))

        %{
          module: module,
          surface: key,
          change: :changed,
          before: old[key],
          after: new[key],
          compatible: not breaking,
          review:
            key in ~w(responsibility description metadata consumes subscriptions commands notifications)
        }
      end

    changes ++
      for error <- errors,
          not Enum.any?(
            ~w(operations props commands notifications),
            &(&1 == Map.get(error, :surface))
          ),
          do: %{
            module: module,
            surface: "compatibility",
            change: :changed,
            compatible: false,
            detail: error
          }
  end

  def render(report) do
    (["Architecture changes", "", "Compatible changes"] ++
       Enum.map(report.compatible, &line("+", &1)) ++
       ["", "Incompatible changes"] ++
       Enum.map(report.incompatible, &line("!", &1)) ++
       ["", "Architecture diagnostics"] ++
       Enum.map(report.diagnostics, &Info.encode/1))
    |> Enum.join("\n")
  end

  defp line(marker, change), do: "#{marker} #{change.module} #{change.surface}: #{change.change}"

  @doc "Review signals for explicit source calls. Dynamic dispatch and semantic cohesion require review."
  def diagnose(sources, contracts) do
    owners = contracts |> export() |> Map.new(&{String.trim_leading(&1["module"], "Elixir."), &1})

    sources
    |> Enum.flat_map(fn {path, source} ->
      {:ok, ast} = Code.string_to_quoted(source)

      {_, findings} =
        Macro.prewalk(ast, [], fn
          {{:., _, [{:__aliases__, _, parts}, :send_update]}, meta, args} = node, findings ->
            if parts == [:Phoenix, :LiveView] and Enum.any?(args, &reserved_delivery?/1),
              do:
                {node,
                 [
                   %{
                     file: path,
                     line: meta[:line],
                     severity: :error,
                     reason: :contract_bypassing_delivery
                   }
                   | findings
                 ]},
              else: {node, findings}

          {{:., _, [{:__aliases__, _, parts}, function]}, meta, _} = node, findings ->
            name = Enum.map_join(parts, ".", &to_string/1)

            private_owner =
              owners
              |> Map.keys()
              |> Enum.sort_by(&String.length/1, :desc)
              |> Enum.find(&String.starts_with?(name, &1 <> "."))

            if private_owner && function not in [:__info__, :module_info],
              do:
                {node,
                 [
                   %{
                     file: path,
                     line: meta[:line],
                     severity: :warning,
                     reason: :private_owner_call,
                     owner: private_owner,
                     target: name
                   }
                   | findings
                 ]},
              else: {node, findings}

          node, findings ->
            {node, findings}
        end)

      findings
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&Info.encode/1)
  end

  defp reserved_delivery?(list) when is_list(list),
    do:
      Keyword.keyword?(list) and
        Enum.any?([:command, :notification, :__domain_contract__], &Keyword.has_key?(list, &1))

  defp reserved_delivery?(_), do: false
end

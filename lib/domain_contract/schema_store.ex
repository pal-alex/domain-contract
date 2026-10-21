defmodule DomainContract.SchemaStore do
  @moduledoc "Immutable runtime schemas owned by current installations and prepared metadata."
  use GenServer

  def start_link(options) do
    case Process.whereis(__MODULE__) do
      nil ->
        GenServer.start_link(__MODULE__, options, name: __MODULE__)

      pid ->
        Process.link(pid)
        {:ok, pid}
    end
  end

  def retain(holder, schemas) when is_map(schemas), do: call({:retain, holder, schemas, :union})

  def replace(holder, schemas) when is_map(schemas),
    do: call({:retain, holder, schemas, :replace})

  def release(holder), do: call({:release, holder})
  def stats, do: call(:stats)

  def fetch(id) when is_binary(id) do
    case :persistent_term.get({__MODULE__, id}, :missing) do
      :missing -> {:error, {:invalid_contract, :expired_context}}
      schema -> {:ok, schema}
    end
  end

  def fetch!(id) when is_binary(id), do: :persistent_term.get({__MODULE__, id})
  def available?(id), do: :persistent_term.get({__MODULE__, id}, :missing) != :missing

  def approved?(required, offered) when required == offered, do: true

  def approved?(required, offered),
    do: :persistent_term.get({__MODULE__, :link, required, offered}, false)

  def approve(required, offered) do
    if approved?(required, offered) do
      :ok
    else
      with {:ok, provider} <- fetch(offered),
           {:ok, expected} <- fetch(required),
           :ok <- DomainContract.Compatibility.satisfies(provider, expected),
           do: call({:approve, required, offered})
    end
  end

  defp call(message) do
    # Compilation and offline BEAM tooling also create bindings without starting applications.
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end

    GenServer.call(__MODULE__, message)
  end

  @impl true
  def init(_),
    do: {:ok, %{holders: %{}, monitors: %{}, ids: MapSet.new(), links: MapSet.new()}}

  @impl true
  def handle_call({:approve, required, offered}, _from, state) do
    if MapSet.member?(state.ids, required) and MapSet.member?(state.ids, offered) do
      :persistent_term.put({__MODULE__, :link, required, offered}, true)
      {:reply, :ok, %{state | links: MapSet.put(state.links, {required, offered})}}
    else
      {:reply, {:error, {:invalid_contract, :expired_context}}, state}
    end
  end

  def handle_call({:retain, holder, schemas, mode}, _from, state) do
    Enum.each(schemas, fn {id, schema} ->
      runtime = schema

      case :persistent_term.get({__MODULE__, id}, :missing) do
        :missing -> :persistent_term.put({__MODULE__, id}, runtime)
        ^runtime -> :ok
        _ -> raise ArgumentError, "conflicting runtime schema #{id}"
      end
    end)

    ids = MapSet.new(Map.keys(schemas))

    ids =
      if mode == :union,
        do: MapSet.union(Map.get(state.holders, holder, MapSet.new()), ids),
        else: ids

    pid = if is_tuple(holder), do: elem(holder, 0), else: holder

    monitors =
      if is_pid(pid) and not Map.has_key?(state.monitors, pid),
        do: Map.put(state.monitors, pid, Process.monitor(pid)),
        else: state.monitors

    state = %{
      state
      | holders: Map.put(state.holders, holder, ids),
        monitors: monitors,
        ids: MapSet.union(state.ids, ids)
    }

    {:reply, :ok, collect(state)}
  end

  def handle_call({:release, holder}, _from, state) do
    holders = Map.delete(state.holders, holder)
    pid = if is_tuple(holder), do: elem(holder, 0), else: holder

    monitors =
      if Enum.any?(Map.keys(holders), fn retained ->
           retained == pid or (is_tuple(retained) and elem(retained, 0) == pid)
         end) do
        state.monitors
      else
        {monitor, monitors} = Map.pop(state.monitors, pid)
        if monitor, do: Process.demonitor(monitor, [:flush])
        monitors
      end

    {:reply, :ok,
     collect(%{
       state
       | holders: holders,
         monitors: monitors
     })}
  end

  def handle_call(:stats, _from, state),
    do: {:reply, %{definitions: MapSet.size(state.ids), holders: map_size(state.holders)}, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _}, state) do
    case state.monitors[pid] do
      ^monitor ->
        holders =
          Map.reject(state.holders, fn {holder, _} ->
            holder == pid or (is_tuple(holder) and elem(holder, 0) == pid)
          end)

        {:noreply,
         collect(%{
           state
           | holders: holders,
             monitors: Map.delete(state.monitors, pid)
         })}

      _ ->
        {:noreply, state}
    end
  end

  defp collect(state) do
    used = state.holders |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    Enum.each(MapSet.difference(state.ids, used), &:persistent_term.erase({__MODULE__, &1}))

    {retained, expired} =
      Enum.split_with(state.links, fn {required, offered} ->
        MapSet.member?(used, required) and MapSet.member?(used, offered)
      end)

    Enum.each(expired, fn {required, offered} ->
      :persistent_term.erase({__MODULE__, :link, required, offered})
    end)

    %{state | ids: used, links: MapSet.new(retained)}
  end
end

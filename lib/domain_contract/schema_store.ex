defmodule DomainContract.SchemaStore do
  @moduledoc "Immutable runtime schemas retained by installations, candidates and monitored context owners."
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
  def pin(holder, ids), do: call({:pin, holder, ids})
  def track(holder, consumer), do: call({:track, holder, consumer})
  def promises(modules, except \\ []), do: call({:promises, modules, except})
  def fetch!(id) when is_binary(id), do: :persistent_term.get({__MODULE__, id})

  def approved?(required, offered) when required == offered, do: true

  def approved?(required, offered),
    do: :persistent_term.get({__MODULE__, :link, required, offered}, false)

  def approve(required, offered) do
    if approved?(required, offered) do
      :ok
    else
      with :ok <- DomainContract.Compatibility.satisfies(fetch!(offered), fetch!(required)),
           do: call({:approve, required, offered})
    end
  end

  @doc "Records admitted links, including expectations retained by older live contexts."
  def approve_bindings(consumers, providers) do
    :ok = retain(self(), DomainContract.Schemas.index(consumers ++ providers))
    offered = Map.new(providers, &{&1["module"], DomainContract.Schemas.id(&1)})

    for consumer <- consumers,
        reference <- consumer["consumes"] || [],
        id = offered[reference["module"]],
        id do
      :ok = approve(reference["schema"], id)
    end

    :ok
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
    do:
      {:ok,
       %{holders: %{}, monitors: %{}, ids: MapSet.new(), consumers: %{}, links: MapSet.new()}}

  @impl true
  def handle_call({:approve, required, offered}, _from, state) do
    :persistent_term.put({__MODULE__, :link, required, offered}, true)
    {:reply, :ok, %{state | links: MapSet.put(state.links, {required, offered})}}
  end

  def handle_call({:track, holder, consumer}, _from, state) do
    if Map.has_key?(state.holders, holder) do
      declarations =
        Map.get(state.consumers, holder, %{})
        |> Map.put(DomainContract.Reference.digest(consumer), consumer)

      {:reply, :ok, %{state | consumers: Map.put(state.consumers, holder, declarations)}}
    else
      # A newly spawned task may finish between pin and track. Its DOWN has
      # already released the lease; do not reinsert an orphan declaration.
      {:reply, :ok, state}
    end
  end

  def handle_call({:promises, modules, except}, _from, state) do
    consumers =
      for {holder, declarations} <- state.consumers,
          holder not in except,
          {_id, consumer} <- declarations,
          consumer["module"] in modules or
            Enum.any?(
              (consumer["consumes"] || []) ++ (consumer["subscriptions"] || []),
              &(&1["module"] in modules)
            ),
          do: consumer

    {:reply, Enum.uniq(consumers), state}
  end

  @impl true
  def handle_call({:pin, holder, ids}, _from, state) do
    if Enum.all?(ids, &MapSet.member?(state.ids, &1)) do
      pid = if is_pid(holder), do: holder, else: elem(holder, 0)

      monitors =
        if Map.has_key?(state.monitors, pid),
          do: state.monitors,
          else: Map.put(state.monitors, pid, Process.monitor(pid))

      ids = MapSet.union(Map.get(state.holders, holder, MapSet.new()), MapSet.new(ids))
      {:reply, :ok, %{state | holders: Map.put(state.holders, holder, ids), monitors: monitors}}
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
        consumers:
          if(mode == :replace, do: Map.delete(state.consumers, holder), else: state.consumers),
        monitors: monitors,
        ids: MapSet.union(state.ids, ids)
    }

    {:reply, :ok, collect(state)}
  end

  def handle_call({:release, holder}, _from, state) do
    {monitor, monitors} = Map.pop(state.monitors, holder)
    if monitor, do: Process.demonitor(monitor, [:flush])

    {:reply, :ok,
     collect(%{
       state
       | holders: Map.delete(state.holders, holder),
         monitors: monitors,
         consumers: Map.delete(state.consumers, holder)
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
             consumers:
               Map.reject(state.consumers, fn {holder, _} ->
                 holder == pid or (is_tuple(holder) and elem(holder, 0) == pid)
               end),
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

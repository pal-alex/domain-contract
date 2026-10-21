Application.load(:midva_sdk)

for path <- :code.get_path(),
    app <- Path.wildcard(Path.join(to_string(path), "*.app")),
    do: app |> Path.basename(".app") |> String.to_atom() |> Application.load()

Config.Reader.read!("config/config.exs", env: :test) |> Application.put_all_env()

root = System.fetch_env!("CONTRACT_EVIDENCE")
phase = System.fetch_env!("CONTRACT_PHASE")

composition =
  Path.join(
    root,
    if(phase == "before", do: "baseline/composition.json", else: "after-composition.json")
  )
  |> File.read!()
  |> Jason.decode!()

started = System.monotonic_time(:millisecond)
directory = Path.join(System.tmp_dir!(), "full-host-#{phase}-#{System.pid()}")
File.mkdir_p!(directory)

{artifacts, headers} =
  Enum.reduce(composition, {%{}, []}, fn row, {paths, headers} ->
    path = Path.join(directory, row["sha256"] <> ".midva")
    File.cp!(row["path"], path)

    {:ok, header} =
      MidvaSDK.Package.inspect_artifact(path, row["target"], %{"digest" => row["sha256"]})

    {Map.put(paths, row["sha256"], path), [header | headers]}
  end)

package_count = length(headers)

plugins =
  Enum.reduce(headers, %{}, fn header, acc ->
    id = header["release"]["id"]
    release = Map.get(acc, id, %{"version" => header["release"]["version"], "parts" => %{}})
    Map.put(acc, id, put_in(release, ["parts", header["target"]], header["digest"]))
  end)

server = Enum.filter(headers, &(&1["target"] == "server"))
runner = Enum.filter(headers, &(&1["target"] == "runner"))

originals =
  Enum.map(headers, &%{manifest: &1["manifest"]}) |> MidvaHost.PackageContracts.authorities()

sources =
  Enum.map(headers, fn header ->
    %{
      "snapshot_id" => "bench",
      "id" => header["release"]["id"],
      "version" => header["release"]["version"],
      "target" => header["target"],
      "digest" => header["digest"],
      "domain_contracts" => header["manifest"]["domain_contracts"]
    }
  end)

bootstrap = %{
  "user" => %{"user_id" => "1"},
  "target" => %{"generation" => 1, "endpoint" => "http://localhost:4001"},
  "data_resource_id" => "benchmark-data",
  "identity_verifier" => "benchmark-only",
  "host_image" => "registry.example.test/midva/host@sha256:" <> String.duplicate("0", 64),
  "snapshot" => %{
    "id" => "bench",
    "host_artifact" => String.duplicate("0", 64),
    "plugins" => plugins
  },
  "server_packages" => server,
  "runner_packages" => runner,
  "contract_authorities" => originals,
  "contract_authority_sources" => sources
}

bootstrap =
  if phase == "after",
    do: Map.drop(bootstrap, ~w(contract_authorities contract_authority_sources)),
    else: bootstrap

Application.put_env(:midva_host, :managed, false)
Application.put_env(:midva_host, :ticking, false)
Application.put_env(:midva_host, :storage_adapter, MidvaHost.TestStore)
Application.put_env(:midva_host, :core_bridge, MidvaHost.TestStore)
Application.put_env(:midva_host, :core_user_id, 1)
Application.put_env(:midva_host, :storage_path, Path.join(directory, "documents.sqlite3"))

Application.put_env(:midva_host, :extra_children, [
  MidvaHost.TestStore,
  {MidvaHost.Storage.Provider, path: Path.join(directory, "identity.sqlite3")}
])

:ok = MidvaHost.Bootstrap.commit(%{bootstrap: bootstrap, artifacts: artifacts})
bootstrap = Application.fetch_env!(:midva_host, :bootstrap)
:erlang.garbage_collect(self())
{:ok, _} = Application.ensure_all_started(:midva_host)

wait = fn wait, deadline ->
  case GenServer.call(MidvaHost.Runtime, :ready, 300_000) do
    true ->
      :ok

    false ->
      if System.monotonic_time(:millisecond) > deadline,
        do: raise("Host startup did not become ready: #{inspect(MidvaHost.Runtime.status())}")

      receive do
      after
        25 -> wait.(wait, deadline)
      end
  end
end

:ok = wait.(wait, started + 300_000)
cold_ms = System.monotonic_time(:millisecond) - started
unavailable = Enum.filter(MidvaHost.Runtime.catalog(), &(&1["status"] != "available"))

if unavailable != [],
  do:
    raise(
      "Unavailable selected plugins: #{inspect(Enum.map(unavailable, &Map.take(&1, ~w(id unavailable_dependency))))}"
    )

:ok = Agent.update(MidvaHost.TestStore, &Map.put(&1, :benchmark_data, "preserve-data"))

receive do
after
  10_000 -> :ok
end

rss = fn ->
  status = File.read!("/proc/self/status")

  Map.new([{:peak_rss_bytes, "VmHWM"}, {:steady_rss_bytes, "VmRSS"}], fn {key, field} ->
    [_, kb] = Regex.run(Regex.compile!(field <> ":\\s+(\\d+)"), status)
    {key, String.to_integer(kb) * 1024}
  end)
end

metrics =
  rss.()
  |> Map.merge(%{
    packages: package_count,
    plugins: map_size(plugins),
    cold_ms: cold_ms,
    bootstrap_json_bytes:
      byte_size(Jason.encode!(Application.fetch_env!(:midva_host, :bootstrap))),
    terms: GenServer.call(MidvaHost.Runtime, :resource_sizes),
    vm_memory_bytes: :erlang.memory(:total)
  })

IO.puts("FULL_HOST_READY:" <> Jason.encode!(metrics))

if candidate_path = System.get_env("CONTRACT_UPDATE_ARTIFACT") do
  {:ok, replacement} = MidvaSDK.Package.inspect_artifact(candidate_path, "server", %{})
  id = replacement["release"]["id"]

  next =
    bootstrap
    |> put_in(["snapshot", "id"], "updated")
    |> put_in(["snapshot", "plugins", id, "parts", "server"], replacement["digest"])

  live =
    DynamicSupervisor.which_children(MidvaSDK.ServiceProcesses)
    |> Enum.map(&elem(&1, 1))
    |> MapSet.new()

  runtime = Process.whereis(MidvaHost.Runtime)

  {hot_us, result} =
    :timer.tc(fn ->
      MidvaHost.Deployment.activate(next, "bench",
        artifact_directory: directory,
        fetch: fn _, _ -> {:ok, File.read!(candidate_path)} end
      )
    end)

  metrics =
    Map.merge(metrics, %{
      hot_ms: hot_us / 1000,
      update: inspect(result),
      same_host: runtime == Process.whereis(MidvaHost.Runtime),
      data_preserved: Agent.get(MidvaHost.TestStore, & &1[:benchmark_data]) == "preserve-data",
      services_preserved:
        MapSet.subset?(
          live,
          MapSet.new(
            Enum.map(DynamicSupervisor.which_children(MidvaSDK.ServiceProcesses), &elem(&1, 1))
          )
        )
    })

  IO.puts("FULL_HOST_UPDATE:" <> Jason.encode!(metrics))
  File.write!(Path.join(root, "full-host-#{phase}.json"), Jason.encode!(metrics, pretty: true))
else
  File.write!(Path.join(root, "full-host-#{phase}.json"), Jason.encode!(metrics, pretty: true))
end

if phase == "after" and System.get_env("CONTRACT_SERIES") do
  preferences = Enum.find(composition, &(&1["id"] == "preferences" and &1["target"] == "server"))
  replacement = System.fetch_env!("CONTRACT_UPDATE_ARTIFACT")

  samples =
    for revision <- 1..6 do
      artifact = if rem(revision, 2) == 1, do: preferences["path"], else: replacement
      {:ok, header} = MidvaSDK.Package.inspect_artifact(artifact, "server", %{})
      current = Application.fetch_env!(:midva_host, :bootstrap)
      expected = current["snapshot"]["id"]

      next =
        bootstrap
        |> put_in(["snapshot", "id"], "series-#{revision}")
        |> put_in(["snapshot", "plugins", "preferences", "parts", "server"], header["digest"])

      fetch = fn _, _ -> {:ok, File.read!(artifact)} end

      terms =
        Task.async(fn ->
          {:ok, staged} =
            MidvaHost.Bootstrap.stage(
              bootstrap: next,
              artifact_directory: directory,
              fetch: fetch
            )

          {:ok, candidate} = MidvaHost.Deployment.prepare(staged)
          transferred = MidvaHost.Deployment.transfer(candidate)

          %{
            external_bytes: :erlang.external_size(transferred),
            heap_bytes: :erts_debug.flat_size(transferred) * :erlang.system_info(:wordsize)
          }
        end)
        |> Task.await(120_000)

      {elapsed, :ok} =
        :timer.tc(fn ->
          Task.async(fn ->
            MidvaHost.Deployment.activate(next, expected,
              artifact_directory: directory,
              fetch: fetch
            )
          end)
          |> Task.await(120_000)
        end)

      :erlang.garbage_collect(self())

      receive do
      after
        3000 -> :ok
      end

      sample =
        Map.merge(rss.(), %{
          revision: revision,
          hot_ms: elapsed / 1000,
          schemas: DomainContract.SchemaStore.stats(),
          transferred: terms
        })

      IO.puts("SERIES:" <> Jason.encode!(sample))
      sample
    end

  File.write!(Path.join(root, "full-host-series.json"), Jason.encode!(samples, pretty: true))
end

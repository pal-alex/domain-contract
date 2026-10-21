Application.load(:midva_sdk)

for path <- :code.get_path(),
    app <- Path.wildcard(Path.join(to_string(path), "*.app")) do
  app |> Path.basename(".app") |> String.to_atom() |> Application.load()
end

root = System.fetch_env!("CONTRACT_EVIDENCE")

composition =
  Path.join(
    root,
    if(System.fetch_env!("CONTRACT_PHASE") == "before",
      do: "baseline/composition.json",
      else: "after-composition.json"
    )
  )
  |> File.read!()
  |> Jason.decode!()

size = fn value ->
  %{
    external_bytes: :erlang.external_size(value),
    heap_bytes: :erts_debug.flat_size(value) * :erlang.system_info(:wordsize)
  }
end

{prepare_us, packages} =
  :timer.tc(fn ->
    Enum.map(composition, fn row ->
      {:ok, package} =
        MidvaSDK.Package.prepare(row["path"], row["target"], %{"digest" => row["sha256"]})

      package
    end)
  end)

{catalog_us, catalog_result} = :timer.tc(fn -> MidvaSDK.Catalog.partition(packages, "server") end)

catalog =
  case catalog_result do
    {:ok, catalog, _active, _unavailable} ->
      catalog

    error ->
      IO.inspect(error, label: "catalog_result", limit: 10)
      %{}
  end

{invocation_us, prepared} =
  :timer.tc(fn ->
    Enum.map(packages, fn package ->
      owner = hd(package.contracts)

      binding =
        DomainContract.Context.new(owner, package.manifest["id"], fn _, _, _, _ ->
          {:error, :benchmark}
        end)

      Map.put(package, :invocation, binding)
    end)
  end)

runtime_packages =
  if function_exported?(MidvaSDK.Package, :runtime, 1),
    do: Enum.map(prepared, &MidvaSDK.Package.runtime/1),
    else: prepared

bootstrap = %{"packages" => Enum.map(packages, & &1.manifest)}

bootstrap =
  if function_exported?(DomainContract.Schemas, :pack, 1),
    do: DomainContract.Schemas.pack(bootstrap),
    else: bootstrap

metrics = %{
  packages: length(packages),
  definitions_json_bytes:
    byte_size(
      Jason.encode!(
        if(function_exported?(DomainContract.Schemas, :bundle, 1),
          do: DomainContract.Schemas.bundle(Enum.flat_map(packages, & &1.contracts)),
          else: Enum.map(packages, & &1.contracts)
        )
      )
    ),
  bootstrap_json_bytes: byte_size(Jason.encode!(bootstrap)),
  packages_term: size.(packages),
  runtime_state_term: size.(runtime_packages),
  catalog_term: size.(catalog),
  invocation_term: size.(prepared),
  context_term: size.(hd(prepared).invocation),
  prepare_ms: prepare_us / 1000,
  catalog_ms: catalog_us / 1000,
  invocation_ms: invocation_us / 1000
}

:erlang.garbage_collect()
metrics = Map.put(metrics, :vm_memory_bytes, :erlang.memory(:total))
status = File.read!("/proc/self/status")

metrics =
  Map.merge(
    metrics,
    Map.new([{:peak_rss_bytes, "VmHWM"}, {:steady_rss_bytes, "VmRSS"}], fn {key, field} ->
      [_, kb] = Regex.run(Regex.compile!(field <> ":\\s+(\\d+)"), status)
      {key, String.to_integer(kb) * 1024}
    end)
  )

IO.puts("METRICS:" <> Jason.encode!(metrics))

File.write!(
  Path.join(root, System.fetch_env!("CONTRACT_PHASE") <> ".json"),
  Jason.encode!(metrics, pretty: true)
)

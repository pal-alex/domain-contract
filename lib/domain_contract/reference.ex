defmodule DomainContract.Reference do
  @moduledoc "Deterministic public-module metadata resolution; never activates provider code."
  alias DomainContract.Artifact
  alias DomainContract.Info
  defstruct [:module, :definition, optional: false, __spark_metadata__: nil]

  @doc "Reads the module's own compiled metadata without executing or loading its code."
  def compiled(module) do
    case :code.which(module) do
      path when is_list(path) and path != [] ->
        with {:ok, bytes} <- File.read(path),
             {:ok, artifact} <- Artifact.from_beam(bytes),
             do: artifact,
             else: (_ -> resolve(module))

      _ ->
        resolve(module)
    end
  end

  def resolve(module) when is_atom(module) and not is_nil(module) do
    paths = Application.get_env(:domain_contract, :metadata_paths, [])

    artifacts =
      Enum.flat_map(paths, fn path ->
        path |> Path.expand() |> Path.wildcard() |> Enum.flat_map(&List.wrap(load(&1)))
      end)

    external = Enum.filter(artifacts, &(&1["module"] == Atom.to_string(module)))

    compiled =
      case :code.which(module) do
        path when is_list(path) and path != [] ->
          case File.read(path) do
            {:error, :enoent} ->
              []

            {:error, reason} ->
              raise File.Error,
                reason: reason,
                action: "read contract metadata",
                path: to_string(path)

            {:ok, bytes} ->
              case Artifact.from_beam(bytes) do
                {:ok, artifact} ->
                  [artifact]

                {:error, :not_contract} ->
                  []

                error ->
                  raise ArgumentError,
                        "invalid contract metadata #{inspect(module)}: #{inspect(error)}"
              end
          end

        _ ->
          []
      end

    loaded =
      if compiled == [] and :code.is_loaded(module) != false and
           function_exported?(module, :__contract__, 0),
         do: [module.__contract__()],
         else: []

    candidates = if external == [], do: compiled ++ loaded, else: external

    candidates =
      if candidates == [] do
        case Code.ensure_compiled(module) do
          {:module, _} ->
            if function_exported?(module, :__contract__, 0), do: [module.__contract__()], else: []

          _ ->
            []
        end
      else
        candidates
      end

    candidates = Enum.uniq_by(candidates, &snapshot/1)

    case candidates do
      [artifact] ->
        if Artifact.validate(artifact) != :ok,
          do: raise(ArgumentError, "invalid contract #{inspect(module)}")

        artifact

      [] ->
        raise ArgumentError, "missing contract metadata for #{inspect(module)}"

      _ ->
        raise ArgumentError, "ambiguous contract metadata for #{inspect(module)}"
    end
  end

  def load(source) when is_atom(source), do: resolve(source)
  def load(source) when is_map(source), do: Info.canonical(source)

  def load(path) when is_binary(path) do
    bytes = File.read!(path)

    if Path.extname(path) == ".beam" do
      {:ok, artifact} = Artifact.from_beam(bytes)
      artifact
    else
      case Jason.decode!(bytes) do
        %{"format_version" => 8, "contracts" => _} = bundle ->
          DomainContract.Schemas.unbundle(bundle)

        value ->
          value
      end
    end
  end

  def snapshot(artifact), do: DomainContract.Schemas.definition(artifact)

  def definition(reference, source \\ %{}), do: DomainContract.Schemas.fetch!(reference, source)

  @doc "Captures a compact requirement from an explicitly selected owner; no provider code is loaded."
  def requirement(owner, optional \\ false) do
    owner = Info.canonical(owner)
    DomainContract.SchemaStore.retain(self(), DomainContract.Schemas.index([owner]))
    owner |> DomainContract.Schemas.reference() |> Map.put("optional", optional)
  end

  def digest(artifact),
    do:
      :crypto.hash(:sha256, Info.encode(Map.delete(artifact, "digest")))
      |> Base.encode16(case: :lower)
end

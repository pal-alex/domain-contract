defmodule DomainContract.Reference do
  @moduledoc "Deterministic public-module metadata resolution; never activates provider code."
  alias DomainContract.Artifact
  alias DomainContract.Info
  defstruct [:module, :definition, :only, optional: false, __spark_metadata__: nil]

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
    resolve(module, true)
  end

  @doc """
  Resolves explicit JSON/BEAM metadata or a BEAM on the code path, without loading
  the owner or calling its metadata functions. Explicit inputs take precedence.
  Already compiled in-memory owners are read through persisted attributes, not callbacks.
  """
  def resolve_metadata(module) when is_atom(module) and not is_nil(module) do
    resolve(module, false)
  end

  defp resolve(module, load_code?) do
    paths = Application.get_env(:domain_contract, :metadata_paths, [])

    artifacts =
      Enum.flat_map(paths, fn path ->
        path |> Path.expand() |> Path.wildcard() |> Enum.flat_map(&List.wrap(load(&1)))
      end)

    external = Enum.filter(artifacts, &(&1["module"] == Atom.to_string(module)))

    loaded =
      if :code.is_loaded(module) != false,
        do:
          Keyword.get(:erlang.get_module_info(module, :attributes), :domain_contract_artifact, []),
        else: []

    compiled =
      case if(loaded == [], do: :code.which(module), else: :already_compiled) do
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

    candidates = if external == [], do: compiled ++ loaded, else: external

    candidates =
      if load_code? and candidates == [] do
        case Code.ensure_compiled(module) do
          {:module, _} ->
            Keyword.get(
              :erlang.get_module_info(module, :attributes),
              :domain_contract_artifact,
              []
            )

          _ ->
            []
        end
      else
        candidates
      end

    candidates = Enum.uniq_by(candidates, &snapshot/1)

    case candidates do
      [artifact] ->
        if artifact["module"] != Atom.to_string(module) or Artifact.validate(artifact) != :ok,
          do: raise(ArgumentError, "invalid contract #{inspect(module)}")

        artifact

      [] ->
        raise ArgumentError, "missing contract metadata for #{inspect(module)}"

      _ ->
        raise ArgumentError, "ambiguous contract metadata for #{inspect(module)}"
    end
  end

  @doc false
  def sources(module) do
    Application.get_env(:domain_contract, :metadata_paths, [])
    |> Enum.flat_map(&(Path.expand(&1) |> Path.wildcard()))
    |> Enum.filter(fn path ->
      Enum.any?(List.wrap(load(path)), &(&1["module"] == Atom.to_string(module)))
    end)
  end

  def load(source) when is_atom(source), do: resolve(source)
  def load(source) when is_map(source), do: Info.canonical(source)

  def load(path) when is_binary(path) do
    bytes = File.read!(path)

    # Compilation resolves the same owner bundles repeatedly. Cache decoding
    # within this compiler process, keyed by the actual bytes so edits are seen.
    case Process.get({__MODULE__, path}) do
      {^bytes, value} ->
        value

      _ ->
        value = decode(path, bytes)
        Process.put({__MODULE__, path}, {bytes, value})
        value
    end
  end

  defp decode(path, bytes) do
    if Path.extname(path) == ".beam" do
      {:ok, artifact} = Artifact.from_beam(bytes)
      artifact
    else
      case Jason.decode!(bytes) do
        %{"format_version" => 9, "contracts" => _} = bundle ->
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

  defdelegate digest(artifact), to: Artifact
end

defmodule Mix.Tasks.Domain.Check do
  @shortdoc "Checks compiled native boundaries or exported contract compatibility"
  @moduledoc """
  To check native boundaries and ownership of a compiled application:

      mix domain.check --application my_app --strict

  `--exclude-dir test/support` excludes an explicit source directory (repeatable).
  This mode compiles with warnings as errors and reads BEAM files without starting
  the application. It cannot be combined with artifact paths or artifact options.

  To check candidate exports against immutable owner exports:

      mix domain.check --authority public.json candidate.json consumer.json

  Repeat --authority for multiple catalog artifacts. Authorities supply definitions,
  not active providers. Without authorities, only definitions in the candidate can
  resolve references.

  To validate source-owner bundles containing both definitions and implementation
  declarations, without selecting active providers:

      mix domain.check --declarations priv/domain_contracts.json other-owner.json

  This checks artifact integrity and conflicting definitions, not provider availability
  or authoritative origin. Deployment activation must still check its selected
  candidate separately. --declarations cannot be combined with --authority.
  No application is started in either mode.
  """
  use Boundary, classify_to: DomainContract
  use Mix.Task

  @impl true
  def run(args) do
    {options, paths, invalid} =
      OptionParser.parse(args,
        strict: [
          authority: :keep,
          declarations: :boolean,
          application: :string,
          strict: :boolean,
          exclude_dir: :keep
        ]
      )

    if invalid != [], do: Mix.raise("invalid domain.check options: #{inspect(invalid)}")

    if options[:application] do
      if paths != [] or Keyword.has_key?(options, :authority) or
           Keyword.has_key?(options, :declarations),
         do: Mix.raise("--application cannot be combined with artifact paths or options")

      Mix.Task.run("compile", ["--warnings-as-errors"])
      check_application(options)
    else
      if Keyword.has_key?(options, :strict) or Keyword.has_key?(options, :exclude_dir),
        do: Mix.raise("--strict and --exclude-dir require --application")

      check_artifacts(options, paths)
    end
  end

  defp check_application(options) do
    result =
      DomainContract.Architecture.check_application(String.to_atom(options[:application]),
        strict: Keyword.get(options, :strict, false),
        exclude_dirs: Keyword.get_values(options, :exclude_dir)
      )

    case result do
      :ok ->
        Mix.shell().info("Domain architecture is valid (#{options[:application]})")

      {:error, diagnostics} ->
        Mix.raise(
          "Invalid domain architecture:\n" <> Enum.map_join(diagnostics, "\n", &inspect/1)
        )
    end
  end

  defp check_artifacts(options, paths) do
    if options[:declarations] && Keyword.has_key?(options, :authority),
      do: Mix.raise("--declarations cannot be combined with --authority")

    Mix.Task.run("compile", ["--warnings-as-errors"])

    if paths == [],
      do:
        Mix.raise(
          "usage: mix domain.check [--declarations | --authority public.json] contracts.json [...]"
        )

    contracts = read(paths)
    authorities = options |> Keyword.get_values(:authority) |> read()

    {result, success} =
      if options[:declarations] do
        {DomainContract.Compatibility.validate(contracts), "Domain declarations are valid"}
      else
        {DomainContract.Compatibility.check(contracts, authorities),
         "Domain contracts are compatible"}
      end

    case result do
      :ok ->
        Mix.shell().info("#{success} (#{length(contracts)} declarations)")

      {:error, errors} ->
        Mix.raise("Incompatible domain contracts: #{inspect(errors, pretty: true)}")
    end
  end

  defp read(paths),
    do:
      Enum.flat_map(
        paths,
        &(File.read!(&1) |> Jason.decode!() |> DomainContract.Schemas.unbundle())
      )
end

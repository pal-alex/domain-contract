defmodule DomainContract.Source do
  @moduledoc "Materializes an exact library revision for source bundles and builds without Git credentials."

  @spec vendor!(String.t(), String.t(), String.t()) :: String.t()
  def vendor!(source, revision, destination) do
    unless Regex.match?(~r/^[0-9a-f]{40}$/, revision),
      do: raise(ArgumentError, "invalid library revision")

    marker = Path.join(destination, ".contract-revision")

    if File.dir?(destination) do
      unless File.read!(marker) == revision <> "\n",
        do: raise("vendored library revision differs")
    else
      File.mkdir_p!(Path.dirname(destination))
      File.mkdir!(destination)

      try do
        if File.exists?(Path.join(source, ".git")) do
          archive = Path.join(destination, "source.tar")
          command!("git", ["-C", source, "archive", "--output=" <> archive, revision])
          command!("tar", ["-xf", archive, "-C", destination])
          File.rm!(archive)
        else
          unless File.read!(Path.join(source, ".contract-revision")) == revision <> "\n",
            do: raise("source bundle does not contain the locked library revision")

          File.cp_r!(source, destination)
        end

        File.write!(marker, revision <> "\n")
      rescue
        error ->
          File.rm_rf!(destination)
          reraise error, __STACKTRACE__
      end
    end

    destination
  end

  defp command!(executable, arguments) do
    case System.cmd(executable, arguments, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> raise "Cannot materialize contract library: #{output}"
    end
  end
end

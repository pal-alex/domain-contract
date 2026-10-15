defmodule DomainContract.SourceTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "source bundles contain the exact locked revision without Git metadata", %{tmp_dir: root} do
    source = Path.join(root, "source")
    File.mkdir!(source)
    git(source, ["init", "-q"])
    File.write!(Path.join(source, "library.ex"), "locked version")
    git(source, ["add", "."])

    git(source, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.test",
      "commit",
      "-qm",
      "initial"
    ])

    revision = git(source, ["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(source, "library.ex"), "uncommitted changes")
    File.write!(Path.join(source, "secret"), "must not enter a bundle")
    output = Path.join(root, "bundle")

    assert ^output = DomainContract.Source.vendor!(source, revision, output)
    assert File.read!(Path.join(output, "library.ex")) == "locked version"
    refute File.exists?(Path.join(output, "secret"))
    refute File.exists?(Path.join(output, ".git"))
    assert DomainContract.Source.vendor!(output, revision, Path.join(root, "second"))
    assert File.read!(Path.join([root, "second", "library.ex"])) == "locked version"

    assert_raise RuntimeError, fn ->
      DomainContract.Source.vendor!(source, String.duplicate("a", 40), output)
    end
  end

  defp git(root, args) do
    {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end
end

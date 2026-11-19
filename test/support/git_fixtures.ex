defmodule SpriteProfiles.GitFixtures do
  @moduledoc """
  Real git repositories for tests, built under a test's tmp dir and served as `file://`
  URLs. Commits use a fixed author and date, so nothing about the machine leaks into them.
  """

  @env [
    {"GIT_AUTHOR_NAME", "Fixture"},
    {"GIT_AUTHOR_EMAIL", "fixture@example.com"},
    {"GIT_COMMITTER_NAME", "Fixture"},
    {"GIT_COMMITTER_EMAIL", "fixture@example.com"},
    {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
    {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"},
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"}
  ]

  @doc "Runs git in `dir` and returns its trimmed output; raises when it fails."
  def git!(dir, args) do
    case System.cmd("git", ["-c", "init.defaultBranch=main" | args],
           cd: dir,
           env: @env,
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{out}"
    end
  end

  @doc "Creates a working repository at `dir`."
  def init!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    dir
  end

  @doc """
  Writes `files` into the working repository: `%{path => content}`, where content is a
  binary, or `{:symlink, target}`. Then commits everything and returns the commit's sha.
  """
  def commit!(dir, files, message \\ "change") do
    Enum.each(files, fn {path, content} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.rm_rf!(full)

      case content do
        {:symlink, target} -> File.ln_s!(target, full)
        body -> File.write!(full, body)
      end
    end)

    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", message])
    git!(dir, ["rev-parse", "HEAD"])
  end

  @doc "An annotated tag on HEAD."
  def tag_annotated!(dir, name), do: git!(dir, ["tag", "-a", name, "-m", name])

  @doc "A lightweight tag on HEAD."
  def tag!(dir, name), do: git!(dir, ["tag", name])

  @doc "Moves HEAD off any branch, so the next commit is reachable only from what tags it."
  def detach!(dir), do: git!(dir, ["checkout", "-q", "--detach"])

  @doc "Checks out a branch again."
  def checkout!(dir, branch), do: git!(dir, ["checkout", "-q", branch])

  @doc "A bare copy of the working repository at `bare`, with every branch and tag; its URL."
  def bare!(dir, bare) do
    git!(Path.dirname(bare), ["clone", "-q", "--bare", "--no-local", dir, bare])
    "file://" <> bare
  end
end

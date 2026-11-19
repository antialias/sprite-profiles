defmodule Mix.Tasks.Profiles.Lock do
  @shortdoc "Pins a set's addresses to commits in a lock file"

  @moduledoc """
  Resolves every address in a set to a commit, fetches it, checks that the set plans, and
  writes a lock file: the set, with every address pinned. `mix profiles.plan` and
  `mix profiles.launch` take it with `--lock FILE`, and then resolve no ref.

      mix profiles.lock -p claude-code -p antialias/sprite-profiles/profiles/preview@main
      mix profiles.lock -p claude-code -p acme/profiles/linear@v1 -o linear.lock
      mix profiles.lock -p claude-code -p github-mcp -i toolsets=repos,issues

  Locking again over an existing file resolves every ref afresh and prints each commit that
  moved (`acme/profiles/linear@v1: 1a2b3c4d → 4d5e6f7a (tag moved)`).

  Options:

    * `--profile`, `-p` - a profile to pick, by name or by address; repeat it, in order
    * `--input`, `-i` - `name=value` for one of the set's inputs; repeat it. The lock
      records the values given (`[inputs]`); an input not given takes its default at use
    * `--output`, `-o` - the lock file to write (default `sprite-profiles.lock`)
    * `--dir` - a folder holding profiles; repeat it to search several

  Exits 1 when the set is refused, 2 on bad usage.
  """

  use Mix.Task

  alias SpriteProfiles.{Lock, Merge, ProfilePath, Resolver, SetArgs}

  @switches [profile: :keep, output: :string, dir: :keep, input: :keep]
  @aliases [p: :profile, o: :output, i: :input]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile", [])
    Mix.Task.run("loadpaths", [])
    Application.ensure_all_started(:req)

    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        picks = Keyword.get_values(opts, :profile)
        dirs = ProfilePath.dirs(Keyword.get_values(opts, :dir))

        case SetArgs.inputs(Keyword.get_values(opts, :input)) do
          {:ok, inputs} -> lock(picks, dirs, opts[:output] || Lock.default_path(), inputs)
          {:usage, message} -> usage(message)
        end

      {_, args, invalid} ->
        usage("not understood: " <> Enum.join(args ++ Enum.map(invalid, &elem(&1, 0)), " "))
    end
  end

  defp usage(extra) do
    Mix.shell().error(
      "usage: mix profiles.lock --profile PICK [--profile PICK ...] [-i NAME=VALUE ...] [-o FILE] [--dir DIR ...]\n" <>
        extra
    )

    exit({:shutdown, 2})
  end

  defp lock(picks, dirs, path, inputs) do
    with :ok <- Merge.check_picks(picks),
         {:ok, profiles} <- Resolver.find(picks, dirs),
         {:ok, _plan} <- Merge.merge(profiles, inputs: inputs) do
      entries = Lock.entries(profiles)
      kinds = for %{source: %{kind: k}, pick: p} <- profiles, into: %{}, do: {p, k}

      moved =
        case File.exists?(path) and Lock.read(path) do
          {:ok, old} -> Lock.diff(old, entries, kinds)
          _ -> []
        end

      Lock.write(path, profiles, inputs)

      Enum.each(profiles, fn
        %{source: nil, pick: p} ->
          Mix.shell().info("  #{p}  (local)")

        %{source: s, pick: p} ->
          Mix.shell().info("  #{p}  #{s.kind} #{s.ref} = #{String.slice(s.sha, 0, 8)}")
      end)

      Enum.each(moved, &Mix.shell().info("Moved: #{&1}"))
      Mix.shell().info("Locked #{length(profiles)} picks in #{path}")
    else
      {:error, problems} ->
        Mix.shell().error("Refused:")
        Enum.each(problems, &Mix.shell().error("  [#{&1.code}] #{&1.message}"))
        exit({:shutdown, 1})
    end
  end
end

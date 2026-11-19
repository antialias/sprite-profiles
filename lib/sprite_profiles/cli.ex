defmodule SpriteProfiles.CLI do
  @moduledoc """
  The `sprite-profiles` command: the entry point of the standalone binary (a Mix release
  wrapped by Burrito), which runs without Erlang, Elixir or Mix installed.

      sprite-profiles plan claude-code github
      sprite-profiles plan -p claude-code -p owner/repo/profile@v1 --agent
      sprite-profiles --version

  `main/1` returns the exit status and writes to stdout and stderr; `run/0` is what the
  release runs while the application starts (see `SpriteProfiles.Application`): it reads the
  arguments, runs `main/1` and halts with its status. It runs inside the application's
  start, so nothing it calls may wait on the application controller (no
  `Application.ensure_all_started/1`; Req is already started as a dependency).

  With no `--dir` and no `SPRITE_PROFILES_PATH`, the search path is the example profiles
  bundled in the release (`priv/profiles`) plus `~/.config/sprite-profiles/profiles` when it
  exists, so a bare name works from any directory.
  """

  alias SpriteProfiles.{Plan, Planner, ProfilePath, SetArgs}

  @plan_switches [
    profile: :keep,
    dir: :keep,
    agent: :boolean,
    lock: :string,
    offline: :boolean,
    input: :keep
  ]
  @plan_aliases [p: :profile, i: :input]

  @help """
  sprite-profiles: composable profiles for Fly.io Sprites

  usage:
    sprite-profiles plan PICK [PICK ...] [-i NAME=VALUE ...] [--dir DIR ...] [--agent] [--offline]
    sprite-profiles plan --lock FILE [--offline] [--dir DIR ...] [--agent]
    sprite-profiles --version
    sprite-profiles help

  commands:
    plan     print the merged plan for a set of profiles, or why it is refused

  A PICK is a profile name or an address (owner/repo[/path]@ref), positional or with
  -p/--profile, in the order to apply them. Exits 1 when the set is refused, 2 on bad usage.
  """

  @doc "What the release runs: `main/1` on the command line's arguments, then halt."
  def run do
    System.halt(main(argv()))
  end

  @doc "Runs the command for `argv` and returns its exit status."
  @spec main([String.t()]) :: non_neg_integer()
  def main(argv) do
    case argv do
      [flag] when flag in ["--version", "-v", "version"] ->
        IO.puts("sprite-profiles #{version()}")
        0

      [cmd | _] when cmd in ["help", "--help", "-h"] ->
        IO.write(@help)
        0

      ["plan" | rest] ->
        plan(rest)

      _ ->
        IO.write(:stderr, @help)
        2
    end
  end

  @doc "The application's version."
  def version, do: to_string(Application.spec(:sprite_profiles, :vsn) || "unknown")

  @doc """
  The search path for `cli_dirs` and the value of `SPRITE_PROFILES_PATH`: as
  `ProfilePath.dirs/2`, except that when neither gives a folder and the release bundles its
  example profiles, the bundled folder takes the place of the working directory's `profiles`.
  """
  def search_path(cli_dirs, env_value \\ System.get_env(ProfilePath.env_var())) do
    bundled = bundled_profiles()

    case ProfilePath.dirs(cli_dirs, env_value) do
      [_repo_dir | rest] when cli_dirs == [] and env_value in [nil, ""] and bundled != nil ->
        [bundled | rest]

      dirs ->
        dirs
    end
  end

  @doc "The example profiles bundled in the release, or `nil` when there are none."
  def bundled_profiles do
    dir = Application.app_dir(:sprite_profiles, "priv/profiles")
    if File.dir?(dir), do: dir
  end

  defp plan(argv) do
    with {:ok, opts} <- parse_plan(argv, []),
         {:ok, picks, resolve_opts} <- set_args(opts) do
      dirs = search_path(Keyword.get_values(opts, :dir))
      caller = if opts[:agent], do: :agent, else: :person

      case Planner.plan(picks, [dirs: dirs, caller: caller] ++ resolve_opts) do
        {:ok, plan} ->
          IO.puts(Plan.format(plan))
          0

        {:error, problems} ->
          refused(problems)
      end
    end
  end

  # Picks may be positional or -p, in any mix; their order is kept.
  defp parse_plan(argv, acc) do
    case OptionParser.parse_head(argv, strict: @plan_switches, aliases: @plan_aliases) do
      {opts, [], []} -> {:ok, acc ++ opts}
      {opts, [pick | rest], []} -> parse_plan(rest, acc ++ opts ++ [profile: pick])
      {_, _, invalid} -> usage("not understood: " <> Enum.map_join(invalid, " ", &elem(&1, 0)))
    end
  end

  defp set_args(opts) do
    case SetArgs.picks(opts) do
      {:ok, [], _} -> usage("name at least one profile, or give --lock")
      {:ok, _, _} = ok -> ok
      {:usage, message} -> usage(message)
      {:error, problems} -> refused(problems)
    end
  end

  defp usage(message) do
    IO.write(:stderr, @help)
    IO.puts(:stderr, "\n" <> message)
    2
  end

  defp refused(problems) do
    IO.puts(:stderr, "Refused:")
    Enum.each(problems, &IO.puts(:stderr, "  [#{&1.code}] #{&1.message}"))
    1
  end

  # Under Burrito the arguments come from the wrapper; elsewhere, from System.argv/0.
  defp argv, do: Burrito.Util.Args.argv()
end

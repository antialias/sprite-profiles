defmodule Mix.Tasks.Profiles.Plan do
  @shortdoc "Prints the merged plan for a set of profiles, or why it is refused"

  @moduledoc """
  Merges a set of profiles and prints the plan: the apply order (privileged profiles after
  the checkpoint), labels, connectors, network policy, env, services, MCP servers, Claude
  settings, skills and files. Nothing is created; no Sprite or token is needed.

      mix profiles.plan --profile claude-code --profile github
      mix profiles.plan --profile claude-code --profile anthropic-key --agent
      mix profiles.plan -p preview -p claude-code --dir path/to/profiles
      mix profiles.plan -p claude-code -p antialias/sprite-profiles/profiles/preview@main
      mix profiles.plan --lock sprite-profiles.lock --offline
      mix profiles.plan -p claude-code -p github-mcp -i readonly=false

  Options:

    * `--profile`, `-p` - a profile to pick, by name or by address
      (`owner/repo[/path]@ref`); repeat it, in the order to apply them
    * `--lock` - a lock file written by `mix profiles.lock`: the set, with every address
      pinned to a commit. Instead of `--profile`
    * `--offline` - call nothing: an address must be pinned (by `--lock` or a full commit)
      and its commit already cached
    * `--dir` - a folder holding profiles; repeat it to search several. With no `--dir` and
      no `SPRITE_PROFILES_PATH`, the search path is `profiles` plus
      `~/.config/sprite-profiles/profiles` when it exists
    * `--input`, `-i` - `name=value` for one of the set's inputs; repeat it. An input not
      given takes its default. Not with `--lock`, which holds its own
    * `--agent` - judge the set as an agent would launch it (privileged sets are refused)

  Exits 1 when the set is refused or a profile is invalid, 2 on bad usage.
  """

  use Mix.Task

  alias SpriteProfiles.{Merge, Plan, ProfilePath, Resolver, SetArgs}

  @switches [
    profile: :keep,
    dir: :keep,
    agent: :boolean,
    lock: :string,
    offline: :boolean,
    input: :keep
  ]
  @aliases [p: :profile, i: :input]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile", [])
    Mix.Task.run("loadpaths", [])
    Application.ensure_all_started(:req)

    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        dirs = ProfilePath.dirs(Keyword.get_values(opts, :dir))
        caller = if opts[:agent], do: :agent, else: :person

        case SetArgs.picks(opts) do
          {:ok, picks, resolve_opts} -> plan(picks, [dirs: dirs, caller: caller] ++ resolve_opts)
          {:usage, message} -> usage(message)
          {:error, problems} -> refused(problems)
        end

      {_, args, invalid} ->
        usage(unexpected(args, invalid))
    end
  end

  defp usage(extra) do
    Mix.shell().error(
      "usage: mix profiles.plan (--profile PICK [--profile PICK ...] [-i NAME=VALUE ...] | --lock FILE) [--offline] [--dir DIR ...] [--agent]" <>
        if(extra == "", do: "", else: "\n" <> extra)
    )

    exit({:shutdown, 2})
  end

  defp unexpected([], []), do: ""

  defp unexpected(args, invalid) do
    "not understood: " <> Enum.join(args ++ Enum.map(invalid, &elem(&1, 0)), " ")
  end

  defp plan(picks, opts) do
    with :ok <- Merge.check_picks(picks),
         {:ok, profiles} <- Resolver.find(picks, opts[:dirs], opts),
         {:ok, plan} <- Merge.merge(profiles, caller: opts[:caller], inputs: opts[:inputs] || %{}) do
      Mix.shell().info(Plan.format(plan))
    else
      {:error, problems} -> refused(problems)
    end
  end

  defp refused(problems) do
    Mix.shell().error("Refused:")
    Enum.each(problems, &Mix.shell().error("  [#{&1.code}] #{&1.message}"))
    exit({:shutdown, 1})
  end
end

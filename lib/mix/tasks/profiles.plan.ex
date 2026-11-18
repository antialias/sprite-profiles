defmodule Mix.Tasks.Profiles.Plan do
  @shortdoc "Prints the merged plan for a set of profiles, or why it is refused"

  @moduledoc """
  Merges a set of profiles and prints the plan: the apply order (privileged profiles after
  the checkpoint), labels, connectors, network policy, env, services, MCP servers, Claude
  settings, skills and files. Nothing is created; no Sprite or token is needed.

      mix profiles.plan --profile claude-code --profile github
      mix profiles.plan --profile claude-code --profile anthropic-key --agent
      mix profiles.plan -p preview -p claude-code --dir path/to/profiles

  Options:

    * `--profile`, `-p` - a profile to pick; repeat it, in the order to apply them
    * `--dir` - a folder holding profiles; repeat it to search several. With no `--dir` and
      no `SPRITE_PROFILES_PATH`, the search path is `profiles` plus
      `~/.config/sprite-profiles/profiles` when it exists
    * `--agent` - judge the set as an agent would launch it (privileged sets are refused)

  Exits 1 when the set is refused or a profile is invalid, 2 on bad usage.
  """

  use Mix.Task

  alias SpriteProfiles.{Merge, Plan, ProfilePath}

  @switches [profile: :keep, dir: :keep, agent: :boolean]
  @aliases [p: :profile]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile", [])
    Mix.Task.run("loadpaths", [])

    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        names = Keyword.get_values(opts, :profile)
        dirs = ProfilePath.dirs(Keyword.get_values(opts, :dir))
        caller = if opts[:agent], do: :agent, else: :person
        plan(names, dirs, caller)

      {_, args, invalid} ->
        Mix.shell().error(
          "usage: mix profiles.plan --profile NAME [--profile NAME ...] [--dir DIR ...] [--agent]" <>
            unexpected(args, invalid)
        )

        exit({:shutdown, 2})
    end
  end

  defp unexpected([], []), do: ""

  defp unexpected(args, invalid) do
    "\nnot understood: " <> Enum.join(args ++ Enum.map(invalid, &elem(&1, 0)), " ")
  end

  defp plan(names, dirs, caller) do
    with :ok <- Merge.check_picks(names),
         {:ok, profiles} <- ProfilePath.find(names, dirs),
         {:ok, plan} <- Merge.merge(profiles, caller: caller) do
      Mix.shell().info(Plan.format(plan))
    else
      {:error, problems} ->
        Mix.shell().error("Refused:")
        Enum.each(problems, &Mix.shell().error("  [#{&1.code}] #{&1.message}"))
        exit({:shutdown, 1})
    end
  end
end

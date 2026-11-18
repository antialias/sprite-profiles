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
    * `--dir` - the folder holding the profiles (default `profiles`)
    * `--agent` - judge the set as an agent would launch it (privileged sets are refused)

  Exits 1 when the set is refused or a profile is invalid, 2 on bad usage.
  """

  use Mix.Task

  alias SpriteProfiles.{Merge, Plan, Profile}

  @switches [profile: :keep, dir: :string, agent: :boolean]
  @aliases [p: :profile]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile", [])
    Mix.Task.run("loadpaths", [])

    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        names = Keyword.get_values(opts, :profile)
        dir = Keyword.get(opts, :dir, "profiles")
        caller = if opts[:agent], do: :agent, else: :person
        plan(names, dir, caller)

      {_, args, invalid} ->
        Mix.shell().error(
          "usage: mix profiles.plan --profile NAME [--profile NAME ...] [--dir DIR] [--agent]" <>
            unexpected(args, invalid)
        )

        exit({:shutdown, 2})
    end
  end

  defp unexpected([], []), do: ""

  defp unexpected(args, invalid) do
    "\nnot understood: " <> Enum.join(args ++ Enum.map(invalid, &elem(&1, 0)), " ")
  end

  defp plan(names, dir, caller) do
    with :ok <- Merge.check_picks(names),
         {:ok, profiles} <- load(names, dir),
         {:ok, plan} <- Merge.merge(profiles, caller: caller) do
      Mix.shell().info(Plan.format(plan))
    else
      {:error, problems} ->
        Mix.shell().error("Refused:")
        Enum.each(problems, &Mix.shell().error("  [#{&1.code}] #{&1.message}"))
        exit({:shutdown, 1})
    end
  end

  defp load(names, dir) do
    results =
      Enum.map(names, fn name ->
        path = Path.join(dir, name)

        if File.dir?(path) do
          Profile.load(path)
        else
          {:error,
           [
             SpriteProfiles.Refusal.new(
               :profile_not_found,
               [name],
               "there is no profile '#{name}' in #{dir}; check the name or pass --dir."
             )
           ]}
        end
      end)

    case Enum.flat_map(results, fn
           {:error, e} -> e
           _ -> []
         end) do
      [] -> {:ok, Enum.map(results, fn {:ok, p} -> p end)}
      errors -> {:error, errors}
    end
  end
end

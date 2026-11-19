defmodule Mix.Tasks.Profiles.Launch do
  @shortdoc "Creates a Sprite and applies a set of profiles to it"

  @moduledoc """
  Creates a Fly.io Sprite, applies a set of profiles to it, checkpoints it as
  `profiled: <set>`, then applies privileged profiles. Prints each step's time as it goes and
  writes a launch record under `~/.local/state/sprite-profiles/launches/`.

      mix profiles.launch --profile claude-code --profile preview --name demo-1
      mix profiles.launch -p claude-code -p github --dry-run
      mix profiles.launch -p claude-code -p anthropic-key --destroy-on-failure
      mix profiles.launch --lock sprite-profiles.lock --name demo-3
      mix profiles.launch -p claude-code -p github-mcp -i readonly=true

  Options:

    * `--profile`, `-p` - a profile to pick: a local name, an address
      (`owner/repo[/path]@ref`) or a published name (`@owner/name[@version]`); repeat it,
      in the order to apply them
    * `--lock` - a lock file written by `mix profiles.lock`, instead of `--profile`; the
      launch uses its commits and resolves no ref
    * `--input`, `-i` - `name=value` for one of the set's inputs; repeat it. An input not
      given takes its default. Not with `--lock`, which holds its own
    * `--offline` - fetch nothing: every address and name must be pinned and cached
    * `--name` - the Sprite's name (default: the picks joined by '-', then 4 hex digits)
    * `--dry-run` - resolve the set and print the plan; create nothing
    * `--destroy-on-failure` - destroy the Sprite if a step after its creation fails
    * `--dir` - a folder holding profiles; repeat it to search several (default: `profiles`
      plus `~/.config/sprite-profiles/profiles` when it exists, or `SPRITE_PROFILES_PATH`)
    * `--secrets-dir` - where privileged profiles' secrets are read from (default
      `~/.config/sprite-profiles/secrets`)
    * `--adapter` - `cli` (default: the installed, logged-in `sprite` CLI) or `api` (REST
      with `SPRITES_TOKEN`)

  Secrets for privileged profiles are read from `<secrets dir>/<NAME>`.
  Exits 1 when the set is refused or a step fails, 2 on bad usage.
  """

  use Mix.Task

  alias SpriteProfiles.{Commands, Out, ProfilePath, SetArgs}

  @switches [
    profile: :keep,
    name: :string,
    dry_run: :boolean,
    destroy_on_failure: :boolean,
    dir: :keep,
    secrets_dir: :string,
    adapter: :string,
    lock: :string,
    offline: :boolean,
    input: :keep
  ]
  @aliases [p: :profile, i: :input]

  @usage "usage: mix profiles.launch (--profile PICK [--profile PICK ...] [-i NAME=VALUE ...] | --lock FILE) [--offline] [--name N] [--dry-run] [--destroy-on-failure] [--dir DIR ...] [--secrets-dir DIR] [--adapter cli|api]"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile", [])
    Mix.Task.run("loadpaths", [])
    Application.ensure_all_started(:req)

    out = SpriteProfiles.MixShell.out(@usage)

    status =
      case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
        {opts, [], []} ->
          case SetArgs.picks(opts) do
            {:ok, picks, set_opts} ->
              command_opts =
                [dirs: ProfilePath.dirs(Keyword.get_values(opts, :dir)), set_opts: set_opts] ++
                  Keyword.take(opts, [
                    :name,
                    :dry_run,
                    :destroy_on_failure,
                    :secrets_dir,
                    :adapter
                  ])

              Commands.Launch.run(picks, command_opts, out)

            {:usage, message} ->
              Out.usage(out, message)

            {:error, problems} ->
              Out.refused(out, problems)
          end

        {_, args, invalid} ->
          Out.usage(
            out,
            "not understood: " <> Enum.join(args ++ Enum.map(invalid, &elem(&1, 0)), " ")
          )
      end

    SpriteProfiles.MixShell.finish(status)
  end

  @doc false
  defdelegate home_relative(path), to: Out
end

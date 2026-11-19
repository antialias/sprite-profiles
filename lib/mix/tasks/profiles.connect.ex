defmodule Mix.Tasks.Profiles.Connect do
  @shortdoc "Creates a profile's custom API connector in your org, with your token"

  @moduledoc """
  Creates or updates, in your org, the custom API connector a profile declares, so the
  profile can be launched: named by the profile's qualified name, pointing at its base URL
  with its auth method, and with an access policy admitting Sprites labelled
  `profile:<qualified name>` and allowing the endpoints it declares.

      mix profiles.connect -p github-mcp
      mix profiles.connect -p acme/profiles/linear@v1
      mix profiles.connect -p @acme/linear

  It prints what it will create, then reads the token from the terminal with echo off and
  sends it to Fly once. The token is never printed, logged or written anywhere. There is no
  flag, variable or pipe that takes a token: without a terminal the command refuses
  (`needs_terminal`), so it is a person's command, never an agent's. An empty line aborts.

  Running it again rotates the token and rewrites the policy. When the profile declares a
  `test_url`, Fly then tests the stored credential and the result is printed.

  Options:

    * `--profile`, `-p` - the profile: a local name, an address or `@owner/name`; exactly
      one
    * `--dir` - a folder holding profiles; repeat it to search several
    * `--adapter` - `cli` (default: the installed, logged-in `sprite` CLI) or `api` (REST
      with `SPRITES_TOKEN`)

  Exits 1 when refused or when Fly refuses the connector, 2 on bad usage.
  """

  use Mix.Task

  alias SpriteProfiles.{Commands, MixShell, Out, ProfilePath}

  @switches [profile: :keep, dir: :keep, adapter: :string]
  @aliases [p: :profile]

  @usage "usage: mix profiles.connect --profile PICK [--dir DIR ...] [--adapter cli|api]"

  @impl Mix.Task
  def run(argv), do: run(argv, [])

  @doc false
  # `deps` replaces the terminal in tests: `:terminal?` (a fun), `:read_token` (a fun) and
  # `:sprites` (a handle).
  def run(argv, deps) do
    Mix.Task.run("compile", [])
    Mix.Task.run("loadpaths", [])
    Application.ensure_all_started(:req)

    out = MixShell.out(@usage)

    status =
      case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
        {opts, [], []} ->
          case Keyword.get_values(opts, :profile) do
            [pick] ->
              command_opts = [
                dirs: ProfilePath.dirs(Keyword.get_values(opts, :dir)),
                adapter: opts[:adapter]
              ]

              Commands.Connect.run(pick, command_opts, out, deps)

            [] ->
              Out.usage(out, "give the profile with -p")

            _ ->
              Out.usage(out, "give one profile; its connector is created alone")
          end

        {_, args, invalid} ->
          Out.usage(
            out,
            "not understood: " <> Enum.join(args ++ Enum.map(invalid, &elem(&1, 0)), " ")
          )
      end

    MixShell.finish(status)
  end
end

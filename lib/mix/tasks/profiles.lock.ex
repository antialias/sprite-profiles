defmodule Mix.Tasks.Profiles.Lock do
  @shortdoc "Pins a set's addresses to commits in a lock file"

  @moduledoc """
  Resolves every address and name in a set to a commit, fetches it, checks that the set
  plans, and writes a lock file: the set, with every address and name pinned.
  `mix profiles.plan` and `mix profiles.launch` take it with `--lock FILE`, and then resolve
  no ref and no name.

      mix profiles.lock -p claude-code -p antialias/sprite-profiles/profiles/preview@main
      mix profiles.lock -p claude-code -p acme/profiles/linear@v1 -o linear.lock
      mix profiles.lock -p claude-code -p @acme/linear@1
      mix profiles.lock -p claude-code -p github-mcp -i toolsets=repos,issues

  Locking again over an existing file resolves every ref afresh and prints each commit that
  moved (`acme/profiles/linear@v1: 1a2b3c4d → 4d5e6f7a (tag moved)`) and each new version
  (`@acme/linear@1: 1.0.0 → 1.1.0 (new version)`).

  Options:

    * `--profile`, `-p` - a profile to pick: a local name, an address or `@owner/name`;
      repeat it, in order
    * `--input`, `-i` - `name=value` for one of the set's inputs; repeat it. The lock
      records the values given (`[inputs]`); an input not given takes its default at use
    * `--output`, `-o` - the lock file to write (default `sprite-profiles.lock`)
    * `--dir` - a folder holding profiles; repeat it to search several

  Exits 1 when the set is refused, 2 on bad usage.
  """

  use Mix.Task

  alias SpriteProfiles.{Commands, Lock, MixShell, Out, ProfilePath, SetArgs}

  @switches [profile: :keep, output: :string, dir: :keep, input: :keep]
  @aliases [p: :profile, o: :output, i: :input]

  @usage "usage: mix profiles.lock --profile PICK [--profile PICK ...] [-i NAME=VALUE ...] [-o FILE] [--dir DIR ...]"

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile", [])
    Mix.Task.run("loadpaths", [])
    Application.ensure_all_started(:req)

    out = MixShell.out(@usage)

    status =
      case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
        {opts, [], []} ->
          case SetArgs.inputs(Keyword.get_values(opts, :input)) do
            {:ok, inputs} ->
              command_opts = [
                dirs: ProfilePath.dirs(Keyword.get_values(opts, :dir)),
                output: opts[:output] || Lock.default_path(),
                inputs: inputs
              ]

              Commands.Lock.run(Keyword.get_values(opts, :profile), command_opts, out)

            {:usage, message} ->
              Out.usage(out, message)
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

defmodule SpriteProfiles.CLI do
  @moduledoc """
  The `sprite-profiles` command: the entry point of the standalone binary (a Mix release
  wrapped by Burrito), which runs without Erlang, Elixir or Mix installed.

      sprite-profiles search linear
      sprite-profiles show @acme/linear
      sprite-profiles plan claude-code github
      sprite-profiles launch claude-code github --name demo
      sprite-profiles exec demo claude -p "Build the weekend page."
      sprite-profiles add claude-code @acme/linear && sprite-profiles lock
      sprite-profiles --version

  `main/2` returns the exit status and writes to stdout and stderr; `run/0` is what the
  release runs while the application starts (see `SpriteProfiles.Application`): it reads the
  arguments, runs `main/2` and halts with its status. It runs inside the application's
  start, so nothing it calls may wait on the application controller (no
  `Application.ensure_all_started/1`; Req is already started as a dependency) or use Mix.
  The commands themselves live in `SpriteProfiles.Commands.*`, shared with the Mix tasks.

  Picks are positional, in the order to apply them; `-p` is still accepted. With no picks
  and no `--lock`, `plan`, `launch` and `lock` read `sprite-profiles.toml` in the working
  directory (`SpriteProfiles.ProjectFile`); picks and that file together are bad usage.

  With no `--dir` and no `SPRITE_PROFILES_PATH`, the search path is the example profiles
  bundled in the release (`priv/profiles`) plus `~/.config/sprite-profiles/profiles` when it
  exists, so a bare name works from any directory. A path pick (`./weekend`) names a profile
  folder directly and leaves the search path as it is, so a project's own profile composes
  with the bundled ones; a relative one is taken from the working directory, or from the
  project file's folder when it comes from that file.
  """

  alias SpriteProfiles.{Commands, Lock, Merge, Out, Pick, ProfilePath, ProjectFile}
  alias SpriteProfiles.{Resolver, SetArgs}

  @help """
  sprite-profiles: composable profiles for Fly.io Sprites

  A profile is a folder that gives a Sprite one thing: an agent, a tool, a connector.
  Find profiles, see what each can touch, and launch a Sprite with a set of them.

  usage: sprite-profiles COMMAND [ARGS] [OPTIONS]

  commands:
    search WORDS...   find published profiles on GitHub
                        sprite-profiles search linear
    show PICK         what one profile reaches and runs, and how to launch it
                        sprite-profiles show @acme/linear
    plan PICK...      the merged plan for a set of profiles, or why it is refused
                        sprite-profiles plan claude-code github
    launch PICK...    create a Sprite and apply the profiles (--dry-run: plan only)
                        sprite-profiles launch claude-code github --name demo
    exec NAME CMD...  run a command in a launched Sprite, with the profiles' env
                        sprite-profiles exec demo claude -p "Build the weekend page."
    connect PICK      create a profile's connector in your org; you type its token
                        sprite-profiles connect github-mcp
    add PICK...       add profiles to this folder's sprite-profiles.toml
                        sprite-profiles add claude-code @acme/linear
    remove PICK...    take profiles out of sprite-profiles.toml
                        sprite-profiles remove @acme/linear
    lock [PICK...]    pin every profile to a commit, in sprite-profiles.lock
                        sprite-profiles lock
    help [COMMAND]    this text, or one command's options

  A PICK is a profile, written one of four ways:
    claude-code                 a profile on the search path (the examples ship inside)
    ./weekend                   a profile folder by path (./, ../, / or ~/), beside the
                                search path; relative to sprite-profiles.toml when in it
    @owner/name[@version]       a published profile on GitHub: the newest version, or
                                the newest of a major or minor, or a branch, as in
                                @acme/linear, @acme/linear@1, @acme/linear@1.2, @acme/linear@main
    owner/repo[/path]@ref       a folder of a GitHub repository at a tag, branch or commit

  In a folder with sprite-profiles.toml, plan, launch and lock take no picks and read it.
  Exit status: 0 done, 1 refused or failed, 2 bad usage.
  """

  @set_help """
  The set: PICKs (positional, or with -p), in the order to apply them; or --lock FILE;
  or, with neither, the profiles in ./sprite-profiles.toml.
  """

  @commands %{
    "plan" => %{
      switches: [
        profile: :keep,
        dir: :keep,
        agent: :boolean,
        lock: :string,
        offline: :boolean,
        input: :keep
      ],
      aliases: [p: :profile, i: :input],
      help:
        """
        usage: sprite-profiles plan [PICK ...] [-i NAME=VALUE ...] [--lock FILE] [--offline] [--dir DIR ...] [--agent]

        Prints the merged plan for a set of profiles (apply order, labels, connectors,
        network, env, services, MCP servers, settings, skills, files), or why it is refused.
        Creates nothing and needs no Sprite.

        """ <>
          @set_help <>
          """

          options:
            -i NAME=VALUE   a value for one of the set's inputs; repeat it
            --lock FILE     plan the set pinned in a lock file
            --offline       call nothing: every published pick must be locked and cached
            --dir DIR       a folder of profiles to search; repeat it
            --agent         judge the set as an agent would launch it

          example:
            sprite-profiles plan claude-code github -i readonly=true
          """
    },
    "launch" => %{
      switches: [
        profile: :keep,
        name: :string,
        dry_run: :boolean,
        destroy_on_failure: :boolean,
        dir: :keep,
        secrets_dir: :string,
        adapter: :string,
        lock: :string,
        offline: :boolean,
        input: :keep,
        verbose: :boolean
      ],
      aliases: [p: :profile, i: :input],
      help:
        """
        usage: sprite-profiles launch [PICK ...] [--name N] [-i NAME=VALUE ...] [--lock FILE] [--dry-run] [--verbose] ...

        Creates a Sprite, applies the profiles to it in order, checkpoints it, then applies
        privileged profiles. Prints a line for the Sprite and one per profile, with its time
        and what it added; a setup.sh's output shows while it runs. Uses the installed,
        logged-in `sprite` CLI.

        """ <>
          @set_help <>
          """

          options:
            --name N              the Sprite's name (default: the picks, then 4 hex digits)
            --dry-run             resolve the set and print its plan; create nothing
            -i NAME=VALUE         a value for one of the set's inputs; repeat it
            --lock FILE           launch the set pinned in a lock file
            --offline             fetch nothing: published picks must be locked and cached
            --destroy-on-failure  destroy the Sprite if a step after its creation fails
            --verbose             print every step and its time, setup.sh's output as it
                                  comes, and a summary
            --secrets-dir DIR     where privileged profiles' secrets are read from
                                  (default ~/.config/sprite-profiles/secrets)
            --adapter cli|api     the sprite CLI (default) or the REST API with SPRITES_TOKEN
            --dir DIR             a folder of profiles to search; repeat it

          example:
            sprite-profiles launch claude-code github --name demo --dry-run
          """
    },
    "exec" => %{
      switches: [adapter: :string],
      aliases: [],
      help: """
      usage: sprite-profiles exec [--adapter cli|api] NAME [--] CMD [ARG ...]

      Runs a command in a launched Sprite as a login shell would (bash -lc), so the
      profiles' env file and shell hooks apply. Prints its output as it comes, stdout and
      stderr together, without the image's "bind: warning: line editing not enabled"
      lines, and exits with the command's status. Standard input is not passed on. Each
      ARG reaches the command as it is; to run a shell line, run bash -c 'LINE'.

      options:
        --adapter cli|api   the sprite CLI (default) or the REST API with SPRITES_TOKEN

      example:
        sprite-profiles exec demo claude -p "Build the weekend page."
      """
    },
    "lock" => %{
      switches: [profile: :keep, output: :string, dir: :keep, input: :keep],
      aliases: [p: :profile, o: :output, i: :input],
      help: """
      usage: sprite-profiles lock [PICK ...] [-i NAME=VALUE ...] [-o FILE] [--dir DIR ...]

      Resolves every published pick to a commit, checks that the set plans, and writes a
      lock file. plan and launch take it with --lock and then resolve nothing.

      The set: PICKs (positional, or with -p), or the profiles in ./sprite-profiles.toml.

      options:
        -o FILE         the lock file (default sprite-profiles.lock, beside
                        sprite-profiles.toml when the set comes from it)
        -i NAME=VALUE   a value for one of the set's inputs; repeat it
        --dir DIR       a folder of profiles to search; repeat it

      example:
        sprite-profiles lock claude-code @acme/linear@1
      """
    },
    "connect" => %{
      switches: [profile: :keep, dir: :keep, adapter: :string],
      aliases: [p: :profile],
      help: """
      usage: sprite-profiles connect PICK [--dir DIR ...] [--adapter cli|api]

      Creates or updates, in your org, the custom API connector a profile declares, so it
      can be launched. Prints what it will create, then reads the token from the terminal
      with echo off and sends it to Fly once; it is never printed or stored. Run it in a
      terminal: there is no flag or pipe for the token. An empty line aborts.

      example:
        sprite-profiles connect github-mcp
      """
    },
    "show" => %{
      switches: [profile: :keep, dir: :keep, offline: :boolean],
      aliases: [p: :profile],
      help: """
      usage: sprite-profiles show PICK [--dir DIR ...] [--offline]

      Resolves one profile as a launch would and prints what it can reach and run: its
      connectors, network, MCP servers, env, skills, setup.sh, whether it is privileged,
      and how to connect and launch it.

      example:
        sprite-profiles show @acme/linear
      """
    },
    "search" => %{
      switches: [],
      aliases: [],
      positional: :word,
      help: """
      usage: sprite-profiles search [WORDS ...]

      Searches GitHub for repositories with the topic sprite-profile and the words, and
      prints one line per profile: its name, newest version, stars, summary and what it
      can touch. Works without a token (10 searches a minute); uses GITHUB_TOKEN when set.

      example:
        sprite-profiles search linear
      """
    },
    "add" => %{
      switches: [profile: :keep, dir: :keep],
      aliases: [p: :profile],
      help: """
      usage: sprite-profiles add PICK ... [--dir DIR ...]

      Resolves each pick and adds it to ./sprite-profiles.toml, creating the file if it is
      missing. A published name is written with its major version (@1), so a later lock
      takes new minor versions but never a new major; a branch, tag or address is written
      as given. A profile already in the file is replaced where it stands.

      example:
        sprite-profiles add claude-code @acme/linear
      """
    },
    "remove" => %{
      switches: [profile: :keep],
      aliases: [p: :profile],
      help: """
      usage: sprite-profiles remove PICK ...

      Takes profiles out of ./sprite-profiles.toml. A name matches with or without its
      version (remove @acme/linear takes out @acme/linear@1).

      example:
        sprite-profiles remove @acme/linear
      """
    }
  }

  @doc """
  What the release runs: `main/2` on the command line's arguments, then halt with its
  status. An exception or exit is one line on stderr and status 70 (EX_SOFTWARE), never a
  crashed VM or an `erl_crash.dump` in the working directory.
  """
  def run do
    if System.get_env("ERL_CRASH_DUMP_SECONDS") in [nil, ""],
      do: System.put_env("ERL_CRASH_DUMP_SECONDS", "0")

    # Output is UTF-8 (★, ·, ✓) whatever the locale: with no LANG, as in `env -i` or a bare
    # container, the VM would otherwise write it as latin1 and garble it.
    :io.setopts(:standard_io, encoding: :unicode)
    :io.setopts(:standard_error, encoding: :unicode)

    System.halt(run_main(argv()))
  end

  @doc false
  # `main/2`, with anything it raises or throws turned into one line and status 70.
  def run_main(argv, ctx \\ []) do
    main(argv, ctx)
  rescue
    e -> crashed(Exception.message(e))
  catch
    kind, reason -> crashed(Exception.format_banner(kind, reason))
  end

  defp crashed(message) do
    line = message |> String.split("\n", trim: true) |> List.first() || "failed"
    IO.puts(:stderr, "sprite-profiles: #{line}")
    70
  end

  @doc """
  Runs the command for `argv` and returns its exit status. `ctx` is for tests: `:cwd`
  (where `sprite-profiles.toml` is looked for; default the working directory) and
  `:connect` (the terminal and Sprites handle of `SpriteProfiles.Commands.Connect.run/4`)
  and `:exec` (options for `SpriteProfiles.Commands.Exec.run/4`, such as `:sprites`).
  """
  @spec main([String.t()], keyword()) :: non_neg_integer()
  def main(argv, ctx \\ []) do
    case argv do
      [flag] when flag in ["--version", "-v", "version"] ->
        IO.puts("sprite-profiles #{version()}")
        0

      [cmd] when cmd in ["help", "--help", "-h"] ->
        IO.write(@help)
        0

      [help, cmd | _] when help in ["help", "--help", "-h"] ->
        command_help(cmd)

      [cmd | rest] when is_map_key(@commands, cmd) ->
        command(cmd, rest, @commands[cmd], ctx)

      [cmd | _] ->
        unknown(cmd)

      [] ->
        IO.write(:stderr, @help)
        2
    end
  end

  defp command_help(cmd) do
    case @commands[cmd] do
      nil ->
        unknown(cmd)

      spec ->
        IO.write(spec.help)
        0
    end
  end

  defp unknown(cmd) do
    IO.write(:stderr, @help)
    IO.puts(:stderr, "\nnot a command: #{cmd}")
    2
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

  ## parsing

  # exec's arguments after NAME are the command's, options and all.
  defp command("exec", argv, spec, ctx) do
    out = Out.io(spec.help)

    case OptionParser.parse_head(argv,
           strict: spec.switches ++ [help: :boolean],
           aliases: [h: :help]
         ) do
      {opts, rest, []} ->
        case {opts[:help], rest} do
          {true, _} ->
            IO.write(spec.help)
            0

          {_, []} ->
            Out.usage(out, "name the Sprite and the command to run")

          {_, [name, "--" | cmd]} when cmd != [] ->
            exec(name, cmd, opts, out, ctx)

          {_, [name | cmd]} when cmd not in [[], ["--"]] ->
            exec(name, cmd, opts, out, ctx)

          _ ->
            Out.usage(out, "name the command to run")
        end

      {_, _, invalid} ->
        Out.usage(out, "not understood: " <> Enum.map_join(invalid, " ", &elem(&1, 0)))
    end
  end

  defp command(cmd, argv, spec, ctx) do
    out = Out.io(spec.help)
    switches = spec.switches ++ [help: :boolean]
    aliases = spec.aliases ++ [h: :help]
    key = Map.get(spec, :positional, :profile)

    case parse(argv, switches, aliases, key, []) do
      {:ok, opts} ->
        if opts[:help] do
          IO.write(spec.help)
          0
        else
          ctx = Keyword.put_new_lazy(ctx, :cwd, &File.cwd!/0)
          run_command(cmd, opts, out, ctx)
        end

      {:usage, message} ->
        Out.usage(out, message)
    end
  end

  # Positional arguments become `key` entries, in order among the options.
  defp parse(argv, switches, aliases, key, acc) do
    case OptionParser.parse_head(argv, strict: switches, aliases: aliases) do
      {opts, [], []} ->
        {:ok, acc ++ opts}

      {opts, ["--" | rest], []} ->
        {:ok, acc ++ opts ++ Enum.map(rest, &{key, &1})}

      {opts, [arg | rest], []} ->
        parse(rest, switches, aliases, key, acc ++ opts ++ [{key, arg}])

      {_, _, invalid} ->
        {:usage, "not understood: " <> Enum.map_join(invalid, " ", &elem(&1, 0))}
    end
  end

  ## the commands

  defp run_command("plan", opts, out, ctx) do
    with {:ok, picks, set_opts, _file} <- the_set(opts, out, ctx) do
      caller = if opts[:agent], do: :agent, else: :person
      Commands.Plan.run(picks, [dirs: dirs(opts), caller: caller] ++ set_opts, out)
    end
  end

  defp run_command("launch", opts, out, ctx) do
    with {:ok, picks, set_opts, _file} <- the_set(opts, out, ctx) do
      command_opts =
        [dirs: dirs(opts), set_opts: set_opts] ++
          Keyword.take(opts, [
            :name,
            :dry_run,
            :destroy_on_failure,
            :secrets_dir,
            :adapter,
            :verbose
          ])

      Commands.Launch.run(picks, command_opts, out)
    end
  end

  defp run_command("lock", opts, out, ctx) do
    cwd = ctx[:cwd]

    with {:ok, picks, set_opts, file} <- the_set(opts, out, ctx, Commands.Lock.no_picks()) do
      {output, shown} =
        cond do
          opts[:output] -> {Path.expand(opts[:output], cwd), opts[:output]}
          file -> {ProjectFile.lock_path(file), Lock.default_path()}
          true -> {Path.expand(Lock.default_path(), cwd), Lock.default_path()}
        end

      # A relative path pick is recorded relative to the lock's folder, where it is read.
      lock_dir = Path.dirname(output)
      picks = Enum.map(picks, &Pick.rebase(&1, set_opts[:base] || cwd, lock_dir))

      command_opts = [
        dirs: dirs(opts),
        output: output,
        shown: shown,
        inputs: set_opts[:inputs] || %{},
        base: lock_dir
      ]

      Commands.Lock.run(picks, command_opts, out)
    end
  end

  defp run_command("connect", opts, out, ctx) do
    with {:ok, pick} <- one_pick(opts, out) do
      command_opts = [dirs: dirs(opts), adapter: opts[:adapter], base: ctx[:cwd]]
      Commands.Connect.run(pick, command_opts, out, ctx[:connect] || [])
    end
  end

  defp run_command("show", opts, out, ctx) do
    with {:ok, pick} <- one_pick(opts, out) do
      command_opts = [
        dirs: dirs(opts),
        bundled: bundled_profiles(),
        offline: opts[:offline] || false,
        base: ctx[:cwd]
      ]

      Commands.Show.run(pick, command_opts, out)
    end
  end

  defp run_command("search", opts, out, _ctx) do
    Commands.Search.run(Keyword.get_values(opts, :word), [], out)
  end

  defp run_command("add", opts, out, ctx) do
    case Keyword.get_values(opts, :profile) do
      [] -> Out.usage(out, "name at least one profile to add")
      picks -> add(picks, dirs(opts), out, ProjectFile.path(ctx[:cwd]))
    end
  end

  defp run_command("remove", opts, out, ctx) do
    case Keyword.get_values(opts, :profile) do
      [] -> Out.usage(out, "name at least one profile to remove")
      picks -> remove(picks, out, ProjectFile.path(ctx[:cwd]))
    end
  end

  defp exec(name, cmd, opts, out, ctx),
    do: Commands.Exec.run(name, cmd, Keyword.take(opts, [:adapter]) ++ (ctx[:exec] || []), out)

  defp dirs(opts), do: search_path(Keyword.get_values(opts, :dir))

  defp one_pick(opts, out) do
    case Keyword.get_values(opts, :profile) do
      [pick] -> {:ok, pick}
      [] -> Out.usage(out, "name the profile")
      _ -> Out.usage(out, "name one profile")
    end
  end

  # The set for plan, launch and lock: picks, --lock, or the project file, and never picks
  # with the file. Returns {:ok, picks, set_opts, project file or nil}, or an exit status.
  defp the_set(opts, out, ctx, no_picks \\ SetArgs.no_picks()) do
    file = ProjectFile.path(ctx[:cwd])
    picks = Keyword.get_values(opts, :profile)
    lock = opts[:lock]

    case {picks, lock, ProjectFile.read(file)} do
      {[_ | _], _, {:ok, _}} ->
        Out.usage(
          out,
          "#{ProjectFile.name()} in this folder names the set, so give no picks; " <>
            "change it with sprite-profiles add or remove, or run from another folder."
        )

      {[], nil, :missing} ->
        Out.usage(out, no_picks)

      {[], nil, {:error, problems}} ->
        Out.refused(out, problems)

      {[], nil, {:ok, %{profiles: []}}} ->
        Out.usage(
          out,
          "#{ProjectFile.name()} lists no profiles; add one with sprite-profiles add PICK"
        )

      {[], nil, {:ok, project}} ->
        from_file(opts, project, file, out)

      _ ->
        with {:ok, picks, set_opts, nil} <- set_args(opts, out, nil) do
          {:ok, picks, Keyword.put_new(set_opts, :base, ctx[:cwd]), nil}
        end
    end
  end

  defp from_file(opts, project, file, out) do
    profiles = Enum.map(project.profiles, &{:profile, &1})

    case set_args(profiles ++ opts, out, file) do
      {:ok, picks, set_opts, file} ->
        inputs = Map.merge(project.inputs, set_opts[:inputs] || %{})
        set_opts = Keyword.merge(set_opts, inputs: inputs, base: Path.dirname(file))
        {:ok, picks, set_opts, file}

      status ->
        status
    end
  end

  defp set_args(opts, out, file) do
    case SetArgs.picks(opts) do
      {:ok, picks, set_opts} ->
        {:ok, picks, set_opts, file}

      {:usage, message} ->
        Out.usage(out, String.replace(message, "mix profiles.lock", "sprite-profiles lock"))

      {:error, problems} ->
        Out.refused(out, problems)
    end
  end

  ## add and remove

  defp add(picks, dirs, out, file) do
    with {:ok, project} <- read_project(file, out),
         :ok <- or_refused(Merge.check_picks(picks), out),
         {:ok, profiles} <-
           or_refused(Resolver.find(picks, dirs, base: Path.dirname(file)), out) do
      written = Enum.map(profiles, &written_pick/1)
      profiles_after = ProjectFile.add(project.profiles, written)

      Enum.zip(profiles, written)
      |> Enum.each(fn {p, w} ->
        id = ProjectFile.identity(w)

        verb =
          case Enum.find(project.profiles, &(ProjectFile.identity(&1) == id)) do
            nil -> "Added"
            ^w -> "Kept"
            old -> "Replaced #{old} with"
          end

        Out.info(out, "#{verb} #{w}#{added_detail(p)}")
      end)

      write_project(file, project, profiles_after)
      Out.info(out, "#{ProjectFile.name()}: #{Enum.join(profiles_after, ", ")}")
      0
    end
  end

  defp added_detail(%{source: nil}), do: "  (local)"
  defp added_detail(%{source: %{version: v}}) when is_binary(v), do: "  (newest: #{v})"
  defp added_detail(%{source: s}), do: "  (#{s.ref} = #{String.slice(s.sha, 0, 8)})"

  # A name picked by version, or with none, is written with its major version, like npm's
  # ^: `@1` for 1.x.y, `@0.2` for 0.2.y (each 0.x may break), `@0.0.3` for 0.0.3. A ref
  # pick, an address and a local name are written as given.
  defp written_pick(%{pick: pick, source: %{version: v}}) when is_binary(v) do
    case Pick.parse(pick) do
      {:ok, %Pick{version: {:ref, _}}} -> pick
      {:ok, p} -> "#{Pick.base(p)}@#{caret(v)}"
      _ -> pick
    end
  end

  defp written_pick(%{pick: pick}), do: pick

  defp caret(v) do
    case String.split(v, ".") do
      ["0", "0", _] -> v
      ["0", minor, _] -> "0.#{minor}"
      [major | _] -> major
    end
  end

  defp remove(picks, out, file) do
    with {:ok, project} <- read_project(file, out) do
      case {project, ProjectFile.remove(project.profiles, picks)} do
        {%{text: nil}, _} ->
          Out.error(out, "There is no #{ProjectFile.name()} here, so nothing to remove.")
          1

        {_, {:ok, profiles}} ->
          write_project(file, project, profiles)
          Enum.each(project.profiles -- profiles, &Out.info(out, "Removed #{&1}"))
          Out.info(out, "#{ProjectFile.name()}: #{Enum.join(profiles, ", ")}")
          0

        {_, {:missing, missing}} ->
          Out.error(
            out,
            "Not in #{ProjectFile.name()}: #{Enum.join(missing, ", ")}; it lists #{Enum.join(project.profiles, ", ")}. Nothing was changed."
          )

          1
      end
    end
  end

  defp read_project(file, out) do
    case ProjectFile.read(file) do
      {:ok, project} -> {:ok, Map.put(project, :text, File.read!(file))}
      :missing -> {:ok, %{profiles: [], inputs: %{}, text: nil}}
      {:error, problems} -> Out.refused(out, problems)
    end
  end

  defp write_project(file, project, profiles),
    do: File.write!(file, ProjectFile.update(project.text, profiles))

  defp or_refused(:ok, _out), do: :ok
  defp or_refused({:ok, _} = ok, _out), do: ok
  defp or_refused({:error, problems}, out), do: Out.refused(out, problems)

  # Under Burrito the arguments come from the wrapper; elsewhere, from System.argv/0.
  defp argv, do: Burrito.Util.Args.argv()
end

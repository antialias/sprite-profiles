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

  alias SpriteProfiles.{Connect, ProfilePath, Sprites}

  @switches [profile: :keep, dir: :keep, adapter: :string]
  @aliases [p: :profile]

  @impl Mix.Task
  def run(argv), do: run(argv, [])

  @doc false
  # `deps` replaces the terminal in tests: `:terminal?` (a fun), `:read_token` (a fun) and
  # `:sprites` (a handle).
  def run(argv, deps) do
    Mix.Task.run("compile", [])
    Mix.Task.run("loadpaths", [])
    Application.ensure_all_started(:req)

    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        case Keyword.get_values(opts, :profile) do
          [pick] -> connect(pick, opts, deps)
          [] -> usage("give the profile with -p")
          _ -> usage("give one profile; its connector is created alone")
        end

      {_, args, invalid} ->
        usage("not understood: " <> Enum.join(args ++ Enum.map(invalid, &elem(&1, 0)), " "))
    end
  end

  defp usage(extra) do
    Mix.shell().error(
      "usage: mix profiles.connect --profile PICK [--dir DIR ...] [--adapter cli|api]\n" <> extra
    )

    exit({:shutdown, 2})
  end

  defp connect(pick, opts, deps) do
    dirs = ProfilePath.dirs(Keyword.get_values(opts, :dir))

    case Connect.load(pick, dirs: dirs) do
      {:ok, profile, connector} ->
        Mix.shell().info(Enum.join(Connect.summary(profile, connector), "\n"))
        terminal? = Keyword.get(deps, :terminal?, &terminal?/0)

        unless terminal?.() do
          refuse(
            :needs_terminal,
            "standard input is not a terminal; the token is typed by a person, with echo off, and never piped or passed in, so run this in a terminal."
          )
        end

        sprites = Keyword.get_lazy(deps, :sprites, fn -> sprites(opts[:adapter] || "cli") end)
        read_token = Keyword.get(deps, :read_token, &read_token/0)

        case read_token.() do
          "" ->
            Mix.shell().error("No token given; nothing was sent.")
            exit({:shutdown, 1})

          token ->
            report(Connect.connect(profile, token, sprites))
        end

      {:error, problems} ->
        Mix.shell().error("Refused:")
        Enum.each(problems, &Mix.shell().error("  [#{&1.code}] #{&1.message}"))
        exit({:shutdown, 1})
    end
  end

  defp report({:ok, %{connector: c, gateway_url: url, test: test}}) do
    Mix.shell().info("""
    Connector #{c.name || "(unnamed)"} is in your org.
      id:          #{c.id}
      gateway URL: #{url}\
    """)

    case test do
      nil ->
        :ok

      %{status: "ok", message: m} ->
        Mix.shell().info("  test:        ok (#{m})")

      %{status: s, message: m} ->
        Mix.shell().error("  test:        #{s} (#{m}); check the token and its permissions.")
        exit({:shutdown, 1})
    end
  end

  defp report({:error, message}) do
    Mix.shell().error("Not connected: #{message}")
    exit({:shutdown, 1})
  end

  defp refuse(code, message) do
    Mix.shell().error("Refused:\n  [#{code}] #{message}")
    exit({:shutdown, 1})
  end

  defp terminal?, do: Keyword.get(:io.getopts(:standard_io), :stdin, false) == true

  # Echo off. Under Mix the shell is "noshell" in cooked mode, where io:get_password/0
  # answers {:error, :enotsup}; in raw mode it reads a line without echoing it. Cooked mode
  # is restored afterwards. The token lives in this function's return value and the
  # caller's variable, and nowhere else.
  defp read_token do
    IO.write(:stderr, "Token (input hidden): ")

    try do
      _ = :shell.start_interactive({:noshell, :raw})
      :io.get_password()
    after
      _ = :shell.start_interactive({:noshell, :cooked})
      IO.write(:stderr, "\n")
    end
    |> case do
      v when is_binary(v) ->
        String.trim(v)

      v when is_list(v) ->
        v |> List.to_string() |> String.trim()

      _ ->
        Mix.shell().error("This terminal cannot read a token with echo off; nothing was sent.")
        exit({:shutdown, 1})
    end
  end

  defp sprites("cli"), do: Sprites.new(Sprites.Cli, [])

  defp sprites("api") do
    case Sprites.Api.from_env() do
      {:ok, cfg, _var} ->
        Sprites.new(Sprites.Api, cfg)

      {:error, message} ->
        Mix.shell().error(message)
        exit({:shutdown, 2})
    end
  end

  defp sprites(other), do: usage("--adapter #{other}")
end

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

  alias SpriteProfiles.{Launcher, Plan, ProfilePath, SetArgs, Sprites}

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

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile", [])
    Mix.Task.run("loadpaths", [])
    Application.ensure_all_started(:req)

    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        case SetArgs.picks(opts) do
          {:ok, names, set_opts} ->
            opts = opts ++ [set_opts: set_opts]
            if opts[:dry_run], do: dry_run(names, opts), else: launch(names, opts)

          {:usage, message} ->
            usage_error(message, "")

          {:error, problems} ->
            refused(problems)
        end

      {_, args, invalid} ->
        usage_error(Enum.join(args ++ Enum.map(invalid, &elem(&1, 0)), " "))
    end
  end

  defp usage_error(extra, prefix \\ "not understood: ") do
    Mix.shell().error(
      "usage: mix profiles.launch (--profile PICK [--profile PICK ...] [-i NAME=VALUE ...] | --lock FILE) [--offline] [--name N] [--dry-run] [--destroy-on-failure] [--dir DIR ...] [--secrets-dir DIR] [--adapter cli|api]" <>
        if(extra == "", do: "", else: "\n" <> prefix <> extra)
    )

    exit({:shutdown, 2})
  end

  defp dry_run(names, opts) do
    case Launcher.resolve(names, resolve_opts(opts)) do
      {:ok, plan, _profiles, _secrets} ->
        Mix.shell().info(Plan.format(plan))
        Mix.shell().info("Dry run: nothing was created.")

      {:error, problems} ->
        refused(problems)
    end
  end

  defp launch(names, opts) do
    sprites = sprites(opts[:adapter] || "cli")

    launch_opts =
      resolve_opts(opts) ++
        [
          sprites: sprites,
          destroy_on_failure: opts[:destroy_on_failure] || false,
          on_step: &print_step/1,
          on_resolved: &print_sources/1
        ]

    Mix.shell().info("Launching #{Enum.join(names, " + ")}")

    case Launcher.launch(names, launch_opts) do
      {:ok, record} ->
        summary(record)

      {:error, %{outcome: :failed} = record} ->
        summary(record)
        Mix.shell().error("Failed at #{step_name(record.error)}: #{record.error.message}")

        unless opts[:destroy_on_failure] or record.steps == [] do
          Mix.shell().error(
            "The Sprite #{record.name} was left as it is; destroy it with: sprite destroy --force #{record.name}"
          )
        end

        exit({:shutdown, 1})

      {:error, problems} ->
        refused(problems)
    end
  end

  defp resolve_opts(opts) do
    [
      dirs: ProfilePath.dirs(Keyword.get_values(opts, :dir)),
      secrets_dir: Keyword.get(opts, :secrets_dir, Launcher.default_secrets_dir()),
      name: opts[:name],
      caller: :person
    ] ++ Keyword.get(opts, :set_opts, [])
  end

  defp print_sources(plan) do
    case Plan.sources(plan) do
      [] -> :ok
      lines -> Mix.shell().info(Enum.join(["Sources:" | Enum.map(lines, &"  #{&1}")], "\n"))
    end
  end

  defp sprites("cli"), do: Sprites.new(Sprites.Cli, [])

  defp sprites("api") do
    case Sprites.Api.from_env() do
      {:ok, cfg, var} ->
        Mix.shell().info("Using the Sprites API with the token in #{var}.")
        Sprites.new(Sprites.Api, cfg)

      {:error, message} ->
        Mix.shell().error(message)
        exit({:shutdown, 2})
    end
  end

  defp sprites(other), do: usage_error("--adapter #{other}")

  defp refused(problems) do
    Mix.shell().error("Refused:")
    Enum.each(problems, &Mix.shell().error("  [#{&1.code}] #{&1.message}"))
    exit({:shutdown, 1})
  end

  defp print_step(s) do
    mark = if s.outcome == :ok, do: " ", else: "!"

    Mix.shell().info(
      "#{mark} #{String.pad_trailing(step_name(s), 34)} #{seconds(s.ms)}  #{one_line(s.detail)}"
    )
  end

  defp step_name(%{step: step, profile: nil}), do: to_string(step)
  defp step_name(%{step: step, profile: p}), do: "#{step} #{p}"

  defp seconds(ms),
    do: String.pad_leading(:erlang.float_to_binary(ms / 1000, decimals: 2), 7) <> " s"

  defp one_line(nil), do: ""

  defp one_line(text),
    do: text |> to_string() |> String.split("\n") |> List.last() |> String.slice(0, 100)

  defp summary(record) do
    setup =
      record.steps
      |> Enum.filter(&(&1.profile != nil))
      |> Enum.group_by(& &1.profile, & &1.ms)
      |> Enum.map(fn {p, ms} -> "#{p} #{seconds(Enum.sum(ms)) |> String.trim()}" end)

    Mix.shell().info("""

    Sprite:     #{record.name}
    URL:        #{record.url || "(unknown)"}
    Labels:     #{Enum.join(record.labels, ", ")} (set #{record.labels_via || "-"})
    Checkpoint: #{record.checkpoint || "(none)"}  "profiled: #{record.set}"
    Per profile: #{Enum.join(setup, "; ")}
    Total:      #{seconds(record.total_ms) |> String.trim()}
    Record:     #{home_relative(record.record_path)}\
    """)
  end

  # Shown as ~/... so a pasted or recorded launch does not carry the local user name.
  @doc false
  def home_relative(nil), do: nil

  def home_relative(path) do
    home = Path.expand("~")

    case Path.relative_to(path, home) do
      ^path -> path
      rel -> Path.join("~", rel)
    end
  end
end

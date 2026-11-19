defmodule SpriteProfiles.Commands.Launch do
  @moduledoc """
  The launch command, shared by `sprite-profiles launch` and `mix profiles.launch`: resolve
  a set, then either print its plan (`dry_run`) or create a Sprite and apply it, printing
  each step as it finishes and a summary. Returns the exit status: 0, 1 (refused or a step
  failed) or 2 (bad usage).

  Options: `:dirs` (the search path), `:set_opts` (from `SpriteProfiles.SetArgs.picks/1`:
  `:inputs`, `:offline`, `:pins`), `:name`, `:dry_run`, `:destroy_on_failure`,
  `:secrets_dir`, `:adapter` (`"cli"` or `"api"`), and for tests `:sprites` (a handle,
  instead of `:adapter`) and `:state_dir` (where the launch record goes).
  """

  alias SpriteProfiles.{Launcher, Out, Plan, Sprites}

  @doc "Runs the command for `picks`; returns the exit status."
  @spec run([String.t()], keyword(), Out.t()) :: non_neg_integer()
  def run(picks, opts, %Out{} = out) do
    if opts[:dry_run], do: dry_run(picks, opts, out), else: launch(picks, opts, out)
  end

  defp dry_run(picks, opts, out) do
    case Launcher.resolve(picks, resolve_opts(opts)) do
      {:ok, plan, _profiles, _secrets} ->
        Out.info(out, Plan.format(plan))
        Out.info(out, "Dry run: nothing was created.")
        0

      {:error, problems} ->
        Out.refused(out, problems)
    end
  end

  defp launch(picks, opts, out) do
    case sprites(opts, out) do
      {:ok, sprites} -> launch(picks, opts, sprites, out)
      {:exit, status} -> status
    end
  end

  defp launch(picks, opts, sprites, out) do
    launch_opts =
      resolve_opts(opts) ++
        [
          sprites: sprites,
          destroy_on_failure: opts[:destroy_on_failure] || false,
          on_step: &print_step(out, &1),
          on_resolved: &print_sources(out, &1)
        ] ++ Keyword.take(opts, [:state_dir])

    Out.info(out, "Launching #{Enum.join(picks, " + ")}")

    case Launcher.launch(picks, launch_opts) do
      {:ok, record} ->
        summary(out, record)
        Out.info(out, done_line(record))
        0

      {:error, %{outcome: :failed} = record} ->
        summary(out, record)
        Out.error(out, "Failed at #{step_name(record.error)}: #{record.error.message}")

        unless opts[:destroy_on_failure] or record.steps == [] do
          Out.error(
            out,
            "The Sprite #{record.name} was left as it is; destroy it with: sprite destroy --force #{record.name}"
          )
        end

        1

      {:error, problems} ->
        Out.refused(out, problems)
    end
  end

  defp resolve_opts(opts) do
    [
      dirs: Keyword.fetch!(opts, :dirs),
      secrets_dir: opts[:secrets_dir] || Launcher.default_secrets_dir(),
      name: opts[:name],
      caller: :person
    ] ++ Keyword.get(opts, :set_opts, [])
  end

  defp sprites(opts, out) do
    case {opts[:sprites], opts[:adapter] || "cli"} do
      {%Sprites{} = sprites, _} ->
        {:ok, sprites}

      {nil, "cli"} ->
        {:ok, Sprites.new(Sprites.Cli, [])}

      {nil, "api"} ->
        case Sprites.Api.from_env() do
          {:ok, cfg, var} ->
            Out.info(out, "Using the Sprites API with the token in #{var}.")
            {:ok, Sprites.new(Sprites.Api, cfg)}

          {:error, message} ->
            Out.error(out, message)
            {:exit, 2}
        end

      {nil, other} ->
        {:exit, Out.usage(out, "not understood: --adapter #{other}")}
    end
  end

  defp print_sources(out, plan) do
    case Plan.sources(plan) do
      [] -> :ok
      lines -> Out.info(out, Enum.join(["Sources:" | Enum.map(lines, &"  #{&1}")], "\n"))
    end
  end

  defp print_step(out, s) do
    mark = if s.outcome == :ok, do: " ", else: "!"

    Out.info(
      out,
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

  defp summary(out, record) do
    setup =
      record.steps
      |> Enum.filter(&(&1.profile != nil))
      |> Enum.group_by(& &1.profile, & &1.ms)
      |> Enum.map(fn {p, ms} -> "#{p} #{seconds(Enum.sum(ms)) |> String.trim()}" end)

    Out.info(out, """

    Sprite:     #{record.name}
    URL:        #{record.url || "(unknown)"}
    Labels:     #{Enum.join(record.labels, ", ")} (set #{record.labels_via || "-"})
    Checkpoint: #{record.checkpoint || "(none)"}  "profiled: #{record.set}"
    Per profile: #{Enum.join(setup, "; ")}
    Total:      #{seconds(record.total_ms) |> String.trim()}
    Record:     #{Out.home_relative(record.record_path)}\
    """)
  end

  @doc """
  The last line of a launch that finished, for a recording: no URL and no checkpoint id.

      ✓ demo: 4 profiles · 2 connectors admitted · checkpointed · 14.2 s
  """
  def done_line(record) do
    checkpointed = if record.checkpoint, do: "checkpointed", else: "not checkpointed"
    total = :erlang.float_to_binary(record.total_ms / 1000, decimals: 1)

    "✓ #{record.name}: #{count(length(record.profiles), "profile")} · " <>
      "#{count(length(record.connectors), "connector")} admitted · #{checkpointed} · #{total} s"
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end

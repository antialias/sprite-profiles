defmodule SpriteProfiles.Commands.Launch do
  @moduledoc """
  The launch command, shared by `sprite-profiles launch` and `mix profiles.launch`: resolve
  a set, then either print its plan (`dry_run`) or create a Sprite and apply it. Returns
  the exit status: 0, 1 (refused or a step failed) or 2 (bad usage).

  By default the output is compact (`SpriteProfiles.LaunchView`): a line for the Sprite,
  one per profile, and the last line with the URL, with `setup.sh`'s output shown while it
  runs. With `:verbose`, each step as it finishes, each line a `setup.sh` prints as it
  prints it, and a summary.

  Options: `:dirs` (the search path), `:set_opts` (from `SpriteProfiles.SetArgs.picks/1`:
  `:inputs`, `:offline`, `:pins`), `:name`, `:dry_run`, `:destroy_on_failure`,
  `:secrets_dir`, `:adapter` (`"cli"` or `"api"`), `:verbose`, and for tests `:sprites` (a
  handle, instead of `:adapter`), `:state_dir` (where the launch record goes),
  `:terminal?` (a fun: may the output redraw lines? default: stdout is a terminal) and
  `:columns` (the terminal's width).
  """

  alias SpriteProfiles.{Launcher, LaunchView, Out, Plan, Sprites}

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
    {callbacks, report} =
      if opts[:verbose], do: verbose(picks, out), else: compact(opts, out)

    launch_opts =
      resolve_opts(opts) ++
        [sprites: sprites, destroy_on_failure: opts[:destroy_on_failure] || false] ++
        callbacks ++ Keyword.take(opts, [:state_dir])

    case Launcher.launch(picks, launch_opts) do
      {:ok, record} ->
        report.({:done, record})
        0

      {:error, %{outcome: :failed} = record} ->
        report.({:failed, record})

        unless opts[:destroy_on_failure] || record.steps == [] do
          Out.error(
            out,
            "The Sprite #{record.name} was left as it is; destroy it with: sprite destroy --force #{record.name}"
          )
        end

        1

      {:error, problems} ->
        report.(:abort)
        Out.refused(out, problems)
    end
  end

  # Today's output: every step, setup.sh's lines as they come, and a summary.
  defp verbose(picks, out) do
    Out.info(out, "Launching #{Enum.join(picks, " + ")}")

    callbacks = [
      on_step: &print_step(out, &1),
      on_output: &print_output(out, &1, &2),
      on_resolved: &print_sources(out, &1)
    ]

    report = fn
      {:done, record} ->
        summary(out, record)
        Out.info(out, done_line(record))

      {:failed, record} ->
        summary(out, record)
        Out.error(out, "Failed at #{step_name(record.error)}: #{record.error.message}")

      :abort ->
        :ok
    end

    {callbacks, report}
  end

  # The compact view: its state in an Agent, since the callbacks come from the launcher.
  defp compact(opts, out) do
    terminal? =
      case Keyword.get(opts, :terminal?, &terminal?/0) do
        f when is_function(f, 0) -> f.()
        value -> value == true
      end

    view = LaunchView.new(terminal: terminal?, columns: opts[:columns] || columns())
    {:ok, agent} = Agent.start_link(fn -> view end)

    emit = fn event ->
      agent
      |> Agent.get_and_update(fn view ->
        {view, ops} = LaunchView.event(view, event)
        {ops, view}
      end)
      |> Enum.each(fn
        {:info, text} -> Out.info(out, text)
        {:error, text} -> Out.error(out, text)
        {:write, text} -> Out.write(out, text)
      end)
    end

    callbacks = [
      on_begin: &emit.({:begin, &1}),
      on_start: &emit.({:start, &1}),
      on_step: &emit.({:step, &1}),
      on_output: &emit.({:output, &1, &2})
    ]

    report = fn event ->
      emit.(event)
      Agent.stop(agent)
    end

    {callbacks, report}
  end

  @doc "True when stdout is a terminal that can take cursor movement."
  def terminal? do
    Keyword.get(:io.getopts(:standard_io), :stdout, false) == true and
      System.get_env("TERM") != "dumb"
  end

  defp columns do
    case :io.columns() do
      {:ok, n} when n > 20 -> n
      _ -> 100
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

  @doc false
  # The Sprites handle for `opts`: `:sprites`, or the adapter `:adapter` names. Returns
  # `{:ok, handle}` or `{:exit, status}`; shared with `SpriteProfiles.Commands.Exec`.
  def sprites(opts, out) do
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

  # A line `setup.sh` printed, as it prints it, under the step it belongs to.
  defp print_output(out, profile, line), do: Out.info(out, "  setup #{profile} | #{line}")

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

  @doc "The last line of a launch that finished; see `SpriteProfiles.LaunchView.done_line/1`."
  defdelegate done_line(record), to: LaunchView
end

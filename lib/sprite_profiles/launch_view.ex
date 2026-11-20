defmodule SpriteProfiles.LaunchView do
  @moduledoc """
  The default, compact output of a launch: one line for the Sprite (the steps before the
  first profile), one line per profile with the time its steps took and what it added, and
  the last line with the URL under it.

      ✓ Sprite demo        1.9 s  2 connectors admitted · network policy · 4 env vars
      ✓ claude-code        4.6 s  setup · MCP context7 · hooks · 1 skill · 1 file
      ✓ preview            0.8 s  service preview :8080 · 1 file
      ✓ demo: 2 profiles · checkpointed · 7.3 s
        https://demo-b6mfx.sprites.app

  While a unit works, a terminal shows a `… <pick>` line with the last lines `setup.sh`
  printed under it, dimmed; when the unit ends that region is erased, line by line (cursor
  up, clear the line; never erase-to-end-of-screen, which would also clear a status bar
  kept on the terminal's last row), and the ✓ line takes its place. Elsewhere (a pipe, an
  agent) nothing is ever erased: the setup lines are printed plainly, indented, then the
  ✓ line.

  Pure. `event/2` takes the launcher's events and returns the view and what to write:
  `{:info, line}` (stdout, with a newline), `{:error, line}` (stderr, with a newline) or
  `{:write, text}` (stdout, as it is: the erase sequences).
  """

  alias SpriteProfiles.Profile

  @live_lines 10
  @failure_lines 20
  @erase_line "\e[1A\e[2K"

  defstruct terminal: false,
            columns: 100,
            name: nil,
            plan: nil,
            profiles: %{},
            width: 12,
            unit: nil,
            label: nil,
            ms: 0,
            lines: [],
            live: 0,
            failed: false

  @type t :: %__MODULE__{}
  @type op :: {:info, String.t()} | {:error, String.t()} | {:write, String.t()}

  @type event ::
          {:begin, %{name: String.t(), plan: SpriteProfiles.Plan.t(), profiles: [Profile.t()]}}
          | {:start, %{step: atom(), profile: String.t() | nil}}
          | {:output, String.t(), String.t()}
          | {:step, map()}
          | {:done, map()}
          | {:failed, map()}
          | :abort

  @doc "A view. Options: `:terminal` (boolean: may it redraw?) and `:columns` (its width)."
  def new(opts \\ []) do
    %__MODULE__{
      terminal: Keyword.get(opts, :terminal, false),
      columns: Keyword.get(opts, :columns, 100)
    }
  end

  @doc "Takes one event; returns `{view, ops}`."
  @spec event(t(), event()) :: {t(), [op()]}
  def event(view, {:begin, %{name: name, plan: plan, profiles: profiles}}) do
    labels = ["Sprite #{name}" | Enum.map(profiles, &pick/1)]
    width = labels |> Enum.map(&String.length/1) |> Enum.max() |> max(12) |> min(40)

    view = %{
      view
      | name: name,
        plan: plan,
        profiles: Map.new(profiles, &{&1.qualified, &1}),
        width: width
    }

    start_unit(view, :head, "Sprite #{name}")
  end

  def event(%{failed: true} = view, {:start, _}), do: {view, []}

  def event(view, {:start, %{step: kind, profile: p}}) do
    cond do
      p != nil and view.unit == {:profile, p} ->
        {view, []}

      p != nil ->
        {view, done} = finish_unit(view)
        {view, drawn} = start_unit(view, {:profile, p}, pick(view.profiles[p], p))
        {view, done ++ drawn}

      view.unit == :head ->
        {view, []}

      # A step between or after the profiles (the checkpoint, the env file before the
      # privileged profiles): it folds into the last line, so it only shows while it works.
      true ->
        {view, done} = finish_unit(view)
        {view, drawn} = start_unit(view, :tail, to_string(kind))
        {view, done ++ drawn}
    end
  end

  def event(view, {:output, _profile, line}) do
    view = %{view | lines: Enum.take(view.lines ++ [line], -@failure_lines)}

    if view.terminal,
      do: redraw(view),
      else: {view, [{:info, "    " <> line}]}
  end

  def event(%{failed: true} = view, {:step, _}), do: {view, []}

  def event(view, {:step, s}),
    do: {%{view | ms: view.ms + s.ms, failed: s.outcome == :failed}, []}

  def event(view, {:done, record}) do
    {view, done} = finish_unit(view)
    url = if record.url, do: [{:info, "  " <> record.url}], else: []
    {view, done ++ [{:info, done_line(record)}] ++ url}
  end

  def event(view, {:failed, record}) do
    error = record.error || %{message: "failed"}
    message = to_string(error.message)
    [first | rest] = String.split(message, "\n")

    first =
      case Regex.run(~r/^exited (\d+):/, first) do
        [_, code] when view.lines != [] -> "setup.sh exited #{code}"
        _ -> first
      end

    # Lines already printed plainly (not a terminal) are right above; a terminal's region
    # was erased, so they are printed again, and an error's own output follows it.
    output =
      cond do
        view.lines != [] and view.terminal -> view.lines
        view.lines != [] -> []
        true -> Enum.take(rest, -@failure_lines)
      end

    line =
      "✗ #{String.pad_trailing(view.label || "launch", view.width)} #{secs(view.ms)}  #{first}"

    {%{view | live: 0, lines: []},
     erase(view) ++ [{:error, line}] ++ Enum.map(output, &{:error, "    " <> &1})}
  end

  def event(view, :abort), do: {%{view | live: 0}, erase(view)}

  @doc """
  The last line of a launch that finished, for a recording: no URL and no checkpoint id.

      ✓ demo: 4 profiles · checkpointed · 14.2 s
  """
  def done_line(record) do
    checkpointed = if record.checkpoint, do: "checkpointed", else: "not checkpointed"
    total = :erlang.float_to_binary(record.total_ms / 1000, decimals: 1)

    "✓ #{record.name}: #{count(length(record.profiles), "profile")} · #{checkpointed} · #{total} s"
  end

  @doc """
  What a profile adds to a Sprite, in a few words: its connector, setup, MCP servers by
  name, services with their port, Claude settings (hooks, N permissions, N settings),
  skills and files.
  """
  @spec added(Profile.t()) :: String.t()
  def added(%Profile{} = p) do
    items =
      [
        connectors(p.connectors),
        if(p.setup, do: "setup"),
        named("MCP", "MCP", Enum.map(p.mcp_servers, & &1.name)),
        named("service", "services", Enum.map(p.services, &service/1))
      ] ++
        claude(p.claude_settings) ++
        [count(length(p.skills), "skill", nil), count(length(p.files), "file", nil)]

    case Enum.reject(items, &is_nil/1) do
      [] -> count(map_size(p.env), "env var", nil) || "nothing to apply"
      items -> Enum.join(items, " · ")
    end
  end

  ## units

  defp start_unit(view, unit, label) do
    view = %{view | unit: unit, label: label, ms: 0, lines: []}
    if view.terminal, do: redraw(view), else: {view, []}
  end

  # The ✓ line of the unit that just ended, in place of its region.
  defp finish_unit(%{unit: unit} = view) when unit in [nil, :tail],
    do: {%{view | live: 0}, erase(view)}

  defp finish_unit(view) do
    added =
      case view.unit do
        :head -> head_added(view.plan)
        {:profile, p} -> added(view.profiles[p])
      end

    line = "✓ #{String.pad_trailing(view.label, view.width)} #{secs(view.ms)}  #{added}"
    {%{view | live: 0}, erase(view) ++ [{:info, line}]}
  end

  defp redraw(view) do
    region =
      ["… " <> view.label | Enum.map(Enum.take(view.lines, -@live_lines), &("    " <> &1))]
      |> Enum.map(&fit(&1, view.columns))
      |> Enum.with_index()
      |> Enum.map(fn
        {line, 0} -> line
        {line, _} -> "\e[2m" <> line <> "\e[0m"
      end)

    {%{view | live: length(region)}, erase(view) ++ [{:info, Enum.join(region, "\n")}]}
  end

  defp erase(%{live: 0}), do: []
  defp erase(%{live: n}), do: [{:write, String.duplicate(@erase_line, n)}]

  # A region line that wrapped would take two rows and break the count to erase.
  defp fit(line, columns) do
    if String.length(line) < columns,
      do: line,
      else: String.slice(line, 0, max(columns - 2, 1)) <> "…"
  end

  ## what each line says

  defp head_added(plan) do
    [
      count(length(plan.connectors), "connector", nil) |> admitted(),
      if(plan.policy, do: "network policy"),
      count(map_size(plan.env), "env var", nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "created"
      items -> Enum.join(items, " · ")
    end
  end

  defp admitted(nil), do: nil
  defp admitted(text), do: text <> " admitted"

  defp pick(%Profile{pick: pick}) when is_binary(pick), do: pick
  defp pick(%Profile{qualified: q}), do: q
  defp pick(nil, name), do: name
  defp pick(profile, _name), do: pick(profile)

  defp connectors([]), do: nil

  defp connectors(list) do
    names =
      Enum.map(list, fn
        %{provider: "custom_api", base_url: url} when is_binary(url) ->
          URI.parse(url).host || url

        %{provider: provider} ->
          provider
      end)

    named("connector", "connectors", names)
  end

  defp named(_one, _many, []), do: nil
  defp named(one, _many, [name]), do: "#{one} #{name}"
  defp named(_one, many, names), do: "#{many} #{Enum.join(names, ", ")}"

  defp service(%{name: name, http_port: port}) when is_integer(port), do: "#{name} :#{port}"
  defp service(%{name: name}), do: name

  defp claude(settings) do
    perms = Map.get(settings, "permissions", %{})
    rules = length(List.wrap(perms["allow"])) + length(List.wrap(perms["deny"]))

    rest =
      settings
      |> Map.drop(["hooks", "permissions"])
      |> Map.put("permissions", Map.drop(perms, ["allow", "deny"]))
      |> leaves()

    [
      if(Map.get(settings, "hooks", %{}) != %{}, do: "hooks"),
      count(rules, "permission", nil),
      count(rest, "setting", nil)
    ]
  end

  defp leaves(map) when is_map(map), do: map |> Map.values() |> Enum.map(&leaves/1) |> Enum.sum()
  defp leaves(_), do: 1

  defp secs(ms),
    do: String.pad_leading(:erlang.float_to_binary(ms / 1000, decimals: 1), 5) <> " s"

  defp count(0, _noun, zero), do: zero
  defp count(n, noun, _zero), do: count(n, noun)
  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end

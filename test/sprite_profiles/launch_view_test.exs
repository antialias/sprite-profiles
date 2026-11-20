defmodule SpriteProfiles.LaunchViewTest do
  use ExUnit.Case, async: true

  alias SpriteProfiles.{LaunchView, Plan, Profile}

  @erase "\e[1A\e[2K"

  defp profile(name, fields) do
    struct!(Profile, [name: name, summary: "s", qualified: name, pick: name] ++ fields)
  end

  defp profiles do
    [
      profile("claude-code",
        setup: "/x/setup.sh",
        mcp_servers: [%{name: "context7"}],
        claude_settings: %{"hooks" => %{"Stop" => []}, "env" => %{"A" => "1"}},
        skills: [%{name: "profiled", source: nil, files: []}]
      ),
      profile("anthropic",
        env: %{"ANTHROPIC_BASE_URL" => {:connector, "custom_api"}},
        connectors: [%{provider: "custom_api", base_url: "https://api.anthropic.com"}]
      ),
      profile("preview",
        services: [%{name: "preview", http_port: 8080}],
        files: [%{source: nil, path: "site/index.html", executable: false}]
      ),
      profile("acme.weekend",
        pick: "./weekend",
        skills: [%{name: "weekend-page", source: nil, files: []}],
        claude_settings: %{"permissions" => %{"allow" => ~w(a b c), "deny" => ["d"]}}
      )
    ]
  end

  @plan %Plan{
    profiles: ~w(claude-code anthropic preview acme.weekend),
    connectors: [%{provider: "custom_api"}],
    policy: [:defaults],
    env: %{"A" => %{}, "B" => %{}, "C" => %{}}
  }

  @record %{
    name: "demo",
    url: "https://demo-1.sprites.app",
    profiles: @plan.profiles,
    connectors: ["custom_api anthropic"],
    checkpoint: "v2",
    total_ms: 12_345,
    error: nil
  }

  # Runs `events` through a view; returns every op, in order.
  defp run(events, opts) do
    {_view, ops} =
      Enum.reduce(events, {LaunchView.new(opts), []}, fn event, {view, ops} ->
        {view, more} = LaunchView.event(view, event)
        {view, ops ++ more}
      end)

    ops
  end

  defp step(kind, profile, ms, outcome \\ :ok),
    do: {:step, %{step: kind, profile: profile, ms: ms, outcome: outcome, detail: nil}}

  defp unit(kind, profile, ms),
    do: [{:start, %{step: kind, profile: profile}}, step(kind, profile, ms)]

  defp launch_events(setup_lines \\ []) do
    # a step with nothing to do starts but never finishes
    [{:begin, %{name: "demo", plan: @plan, profiles: profiles()}}] ++
      unit(:connectors, nil, 400) ++
      unit(:create, nil, 1200) ++
      unit(:policy, nil, 200) ++
      unit(:prepare, nil, 100) ++
      unit(:env, nil, 0) ++
      unit(:files, "claude-code", 300) ++
      [{:start, %{step: :setup, profile: "claude-code"}}] ++
      Enum.map(setup_lines, &{:output, "claude-code", &1}) ++
      [step(:setup, "claude-code", 4_300)] ++
      unit(:files, "anthropic", 0) ++
      [{:start, %{step: :setup, profile: "anthropic"}}] ++
      unit(:services, "preview", 800) ++
      unit(:files, "acme.weekend", 1_300) ++
      unit(:checkpoint, nil, 2_000) ++
      [{:done, @record}]
  end

  test "one line for the Sprite, one per profile, the last line and the URL" do
    ops = run(launch_events(), terminal: false)

    assert ops == [
             {:info,
              "✓ Sprite demo    1.9 s  1 connector admitted · network policy · 3 env vars"},
             {:info,
              "✓ claude-code    4.6 s  setup · MCP context7 · hooks · 1 setting · 1 skill"},
             {:info, "✓ anthropic      0.0 s  connector api.anthropic.com"},
             {:info, "✓ preview        0.8 s  service preview :8080 · 1 file"},
             {:info, "✓ ./weekend      1.3 s  4 permissions · 1 skill"},
             {:info, "✓ demo: 4 profiles · 1 connector admitted · checkpointed · 12.3 s"},
             {:info, "  https://demo-1.sprites.app"}
           ]
  end

  test "not on a terminal, setup.sh's lines are printed plainly and nothing is erased" do
    ops = run(launch_events(["Open https://example/device", "enter ABCD-1234"]), terminal: false)

    texts = Enum.map(ops, &elem(&1, 1))
    i = Enum.find_index(texts, &(&1 == "    Open https://example/device"))
    assert ["    enter ABCD-1234", "✓ claude-code " <> _] = Enum.slice(texts, i + 1, 2)
    assert Enum.at(texts, i - 1) =~ ~r/^✓ Sprite demo /
    refute Enum.any?(ops, &match?({:write, _}, &1))
    refute Enum.any?(texts, &(&1 =~ "\e"))
  end

  test "on a terminal, a live region shows the unit and its last 10 lines, erased line by line" do
    lines = for i <- 1..12, do: "line #{i}"
    ops = run(launch_events(lines), terminal: true, columns: 80)

    # the region after the last setup line: "… claude-code" and lines 3..12, dimmed
    {before, [{:info, "✓ claude-code" <> _} | _]} =
      Enum.split_while(ops, &(not match?({:info, "✓ claude-code" <> _}, &1)))

    [{:info, region}, {:write, erase}] = Enum.take(before, -2)
    assert erase == String.duplicate(@erase, 11)

    assert String.split(region, "\n") ==
             ["… claude-code"] ++ for(i <- 3..12, do: "\e[2m    line #{i}\e[0m")

    # every unit's region is erased before its line; never erase-to-end-of-screen
    assert {:info, "… Sprite demo"} = hd(ops)
    assert {:write, @erase} = Enum.at(ops, 1)
    assert {:info, "✓ Sprite demo" <> _} = Enum.at(ops, 2)
    refute Enum.any?(ops, fn {_, text} -> text =~ "\e[J" or text =~ "\e[0J" end)
    assert List.last(ops) == {:info, "  https://demo-1.sprites.app"}
  end

  test "a region line wider than the terminal is cut, so erasing counts rows right" do
    ops = run(launch_events([String.duplicate("x", 200)]), terminal: true, columns: 40)
    regions = for {:info, "… claude-code" <> _ = r} <- ops, do: r
    [_, line] = regions |> List.last() |> String.split("\n")
    assert String.length(String.replace(line, ~r/\e\[\d+m/, "")) == 39
  end

  describe "a failure" do
    defp failing(lines, terminal) do
      record = %{@record | error: %{step: :setup, profile: "claude-code", message: "exited 1: x"}}

      ([{:begin, %{name: "demo", plan: @plan, profiles: profiles()}}] ++
         unit(:create, nil, 1000) ++
         [{:start, %{step: :setup, profile: "claude-code"}}] ++
         Enum.map(lines, &{:output, "claude-code", &1}) ++
         [step(:setup, "claude-code", 2500, :failed), step(:destroy, nil, 300), {:failed, record}])
      |> run(terminal: terminal)
    end

    test "on a terminal: the ✗ line, then the step's last 20 lines" do
      lines = for i <- 1..25, do: "out #{i}"
      ops = failing(lines, true)
      errors = for {:error, l} <- ops, do: l

      assert errors ==
               ["✗ claude-code    2.5 s  setup.sh exited 1"] ++
                 for(i <- 6..25, do: "    out #{i}")

      assert {:write, _} = Enum.at(ops, -22)
    end

    test "not on a terminal: the lines were printed as they came, so only the ✗ line" do
      ops = failing(["the code expired"], false)
      assert {:info, "    the code expired"} in ops
      assert for({:error, l} <- ops, do: l) == ["✗ claude-code    2.5 s  setup.sh exited 1"]
    end

    test "a step with no output of its own shows its error's lines" do
      record = %{@record | error: %{step: :create, profile: nil, message: "exited 2: a\nb"}}

      ops =
        ([{:begin, %{name: "demo", plan: @plan, profiles: profiles()}}] ++
           [{:start, %{step: :create, profile: nil}}, step(:create, nil, 100, :failed)] ++
           [{:failed, record}])
        |> run(terminal: false)

      assert ops == [{:error, "✗ Sprite demo    0.1 s  exited 2: a"}, {:error, "    b"}]
    end
  end

  test "what a profile adds, in a few words" do
    assert LaunchView.added(profile("e", env: %{"X" => "1"})) == "1 env var"
    assert LaunchView.added(profile("n", [])) == "nothing to apply"

    assert LaunchView.added(
             profile("m",
               connectors: [%{provider: "github", base_url: nil}, %{provider: "linear"}],
               mcp_servers: [%{name: "a"}, %{name: "b"}],
               services: [%{name: "web", http_port: 8080}, %{name: "worker", http_port: nil}]
             )
           ) == "connectors github, linear · MCP a, b · services web :8080, worker"
  end
end

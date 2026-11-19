defmodule SpriteProfiles.LauncherTest do
  # The launch sequence against a stub Sprites adapter; nothing leaves the machine.
  use ExUnit.Case, async: true

  alias SpriteProfiles.{FakeSprites, Launcher}

  @moduletag :tmp_dir

  defp opts(ctx, sprites, extra \\ []) do
    extra ++
      [
        sprites: sprites,
        dir: "profiles",
        name: "demo-1",
        state_dir: Path.join(ctx.tmp_dir, "launches"),
        secrets_dir: Path.join(ctx.tmp_dir, "secrets")
      ]
  end

  defp scripts(log) do
    for [_name, ["bash", "-c", script], _opts] <- FakeSprites.calls(log, :exec), do: script
  end

  defp writes(log),
    do: Map.new(FakeSprites.calls(log, :write_file), fn [_, p, c, m] -> {p, {c, m}} end)

  describe "before any API call" do
    test "a refused set calls nothing", ctx do
      {sprites, log} = FakeSprites.start()

      assert {:error, [r]} =
               Launcher.launch(["claude-code", "claude-code"], opts(ctx, sprites))

      assert r.code == :duplicate_pick
      assert FakeSprites.calls(log) == []
    end

    test "a missing secret is refused locally, naming where it was looked for", ctx do
      {sprites, log} = FakeSprites.start()

      assert {:error, [r]} =
               Launcher.launch(["claude-code", "anthropic-key"], opts(ctx, sprites))

      assert r.code == :secret_missing
      assert r.message =~ Path.join([ctx.tmp_dir, "secrets", "ANTHROPIC_API_KEY"])
      assert FakeSprites.calls(log) == []
    end

    test "a bad Sprite name is refused locally", ctx do
      {sprites, log} = FakeSprites.start()

      assert {:error, [r]} =
               Launcher.launch(["preview"], opts(ctx, sprites, name: "Bad_Name"))

      assert r.code == :bad_sprite_name
      assert FakeSprites.calls(log) == []
    end

    test "resolve/2 is the dry run: a plan and no calls", _ctx do
      assert {:ok, plan, profiles, %{}} = Launcher.resolve(["claude-code", "preview"])
      assert plan.set == "claude-code+preview"
      assert Enum.map(profiles, & &1.name) == ["claude-code", "preview"]
    end
  end

  describe "connectors" do
    test "a missing connector refuses after listing them and before creating", ctx do
      {sprites, log} = FakeSprites.start()

      assert {:error, [r]} = Launcher.launch(["claude-code", "github"], opts(ctx, sprites))
      assert r.code == :connector_missing
      assert Enum.map(FakeSprites.calls(log), &elem(&1, 0)) == [:list_connectors]
    end

    test "an admitting connector resolves the gateway URL into the env file", ctx do
      connector = %{
        id: "conn_1",
        provider: "github",
        allow_all: false,
        sprite_labels: ["profile:github"],
        name_prefix: nil
      }

      {sprites, log} =
        FakeSprites.start(fn
          {:list_connectors, []} -> {:ok, [connector]}
          _ -> :default
        end)

      assert {:ok, record} = Launcher.launch(["claude-code", "github"], opts(ctx, sprites))
      assert record.outcome == :ok

      {env, 0o600} = writes(log)["/home/sprite/.config/profiled/env.sh"]
      assert env =~ "export GITHUB_GATEWAY_URL='https://api.sprites.dev/v1/gateway/github/conn_1'"
    end
  end

  describe "a full launch of claude-code + preview" do
    setup ctx do
      {sprites, log} = FakeSprites.start()
      test_pid = self()
      on_step = fn s -> send(test_pid, {:step, s}) end

      {:ok, record} =
        Launcher.launch(["claude-code", "preview"], opts(ctx, sprites, on_step: on_step))

      %{record: record, log: log}
    end

    test "creates the Sprite with its labels, then sets the policy", %{log: log} do
      assert [
               {:create, ["demo-1", ["profile:claude-code", "profile:preview"]]},
               {:set_policy, [_, policy]} | _
             ] =
               FakeSprites.calls(log)

      assert policy == %{
               "rules" => [
                 %{"include" => "defaults"},
                 %{"action" => "allow", "domain" => "mcp.context7.com"},
                 %{"action" => "allow", "domain" => "console.anthropic.com"},
                 %{"action" => "allow", "domain" => "platform.claude.com"}
               ]
             }

      refute FakeSprites.calls(log, :set_labels) != []
    end

    test "pushes files and skills as a tarball and sets their modes", %{log: log} do
      {tar, 0o600} = writes(log)["/tmp/profiled-claude-code.tar"]
      {:ok, names} = :erl_tar.table({:binary, tar})

      assert Enum.sort(Enum.map(names, &to_string/1)) == [
               ".claude/skills/claude-code--profiled/SKILL.md",
               ".config/profiled/hooks/task-hold.sh"
             ]

      untar = Enum.find(scripts(log), &(&1 =~ "/tmp/profiled-claude-code.tar"))
      assert untar =~ "chmod 0755 '.config/profiled/hooks/task-hold.sh'"
      assert untar =~ "chmod 0644 '.claude/skills/claude-code--profiled/SKILL.md'"
    end

    test "lays Claude settings over the Sprite's, hooks appended", %{log: log} do
      {json, 0o644} = writes(log)["/home/sprite/.claude/settings.json"]
      settings = Jason.decode!(json)
      assert settings["env"] == %{"BASH_DEFAULT_TIMEOUT_MS" => "600000"}

      assert Map.keys(settings["hooks"]) |> Enum.sort() == [
               "PreToolUse",
               "Stop",
               "UserPromptSubmit"
             ]
    end

    test "registers MCP servers at user scope", %{log: log} do
      mcp = Enum.find(scripts(log), &(&1 =~ "claude mcp add-json"))
      assert mcp =~ "claude mcp add-json --scope user 'context7' "
      assert mcp =~ ~s("url":"https://mcp.context7.com/mcp")
      refute mcp =~ "auth"
    end

    test "runs setup.sh through the Task-hold runner with its timeout", %{log: log} do
      {runner, 0o755} = writes(log)["/home/sprite/.config/profiled/run-setup.sh"]
      assert runner =~ "/v1/tasks/$task"
      assert runner =~ "while sleep 60"
      assert {_, 0o755} = writes(log)["/home/sprite/.config/profiled/setup/claude-code.sh"]

      assert [_, ["bash", "-c", run], opts] =
               Enum.find(FakeSprites.calls(log, :exec), fn [_, [_, _, s], _] ->
                 s =~ "run-setup.sh\" "
               end)

      assert run =~ ~s('claude-code' '300' 'claude-code+preview')
      assert opts[:timeout] == 360_000
    end

    test "creates services with ~ expanded", %{log: log} do
      assert [["demo-1", "preview", spec]] = FakeSprites.calls(log, :put_service)
      assert spec.dir == "/home/sprite/site"
      assert spec.http_port == 8080
    end

    test "checkpoints last, with the set in the comment", %{log: log, record: record} do
      assert {:checkpoint, ["demo-1", "profiled: claude-code+preview"]} =
               List.last(FakeSprites.calls(log))

      assert record.checkpoint == "v2"
    end

    test "reports every step and writes a launch record", %{record: record} do
      steps = Enum.map(record.steps, &{&1.step, &1.profile})

      assert steps == [
               {:create, nil},
               {:policy, nil},
               {:prepare, nil},
               {:env, nil},
               {:files, "claude-code"},
               {:settings, "claude-code"},
               {:mcp, "claude-code"},
               {:setup, "claude-code"},
               {:files, "preview"},
               {:services, "preview"},
               {:checkpoint, nil}
             ]

      assert_received {:step, %{step: :create}}
      assert record.labels_via == "create"

      saved = record.record_path |> File.read!() |> Jason.decode!()
      assert saved["name"] == "demo-1"
      assert saved["outcome"] == "ok"
      assert length(saved["steps"]) == 11
    end
  end

  describe "a launch with a fetched profile" do
    setup ctx do
      SpriteProfiles.GitHubFixtures.stub_acme()
      {sprites, log} = FakeSprites.start()
      test_pid = self()

      {:ok, record} =
        Launcher.launch(
          ["preview", "acme/profiles/linear@v1"],
          opts(ctx, sprites,
            cache_dir: Path.join(ctx.tmp_dir, "cache"),
            on_resolved: &send(test_pid, {:resolved, &1})
          )
        )

      %{record: record, log: log}
    end

    test "labels it by its qualified name", %{log: log} do
      assert [{:create, ["demo-1", ["profile:preview", "profile:acme.linear"]]} | _] =
               FakeSprites.calls(log)
    end

    test "names its skills folder, setup script, Task hold and PROFILED_PROFILE by it",
         %{log: log} do
      {tar, _} = writes(log)["/tmp/profiled-acme.linear.tar"]
      {:ok, names} = :erl_tar.table({:binary, tar})
      assert Enum.map(names, &to_string/1) == [".claude/skills/acme.linear--triage/SKILL.md"]

      assert {"#!/usr/bin/env bash\necho linear\n", 0o755} =
               writes(log)["/home/sprite/.config/profiled/setup/acme.linear.sh"]

      run = Enum.find(scripts(log), &(&1 =~ "run-setup.sh\" "))
      assert run =~ ~s('acme.linear' '600' 'preview+acme/profiles/linear@v1')
      # The runner derives the hold and PROFILED_PROFILE from its first argument.
      assert Launcher.runner_script() =~ ~s(PROFILED_PROFILE="$profile")
    end

    @tag :tmp_dir
    test "the runner's Task hold has no '.', which Sprites refuse in a task name", ctx do
      runner = Path.join(ctx.tmp_dir, "run.sh")
      # Run the runner's own name line in bash, with a stand-in for its arguments.
      [line] = Regex.run(~r/^task=.*$/m, Launcher.runner_script())
      File.write!(runner, "profile=acme.linear\n#{line}\nprintf %s \"$task\"")
      assert {"profiled-setup-acme--linear", 0} = System.cmd("bash", [runner])
    end

    test "checkpoints with the picks as written", %{log: log} do
      assert {:checkpoint, ["demo-1", "profiled: preview+acme/profiles/linear@v1"]} =
               List.last(FakeSprites.calls(log))
    end

    test "keeps the sources in the launch record, and shows them before any call",
         %{record: record} do
      assert record.sources == [
               %{
                 pick: "acme/profiles/linear@v1",
                 owner: "acme",
                 repo: "profiles",
                 path: "linear",
                 ref: "v1",
                 sha: SpriteProfiles.GitHubFixtures.sha1()
               }
             ]

      saved = record.record_path |> File.read!() |> Jason.decode!()
      assert [%{"sha" => _, "pick" => "acme/profiles/linear@v1"}] = saved["sources"]
      assert_received {:resolved, plan}
      assert [line] = SpriteProfiles.Plan.sources(plan)
      assert line =~ "publisher acme"
    end

    test "the default Sprite name joins short names" do
      plan = %SpriteProfiles.Plan{profiles: ["claude-code", "acme.linear"]}
      assert Launcher.default_name(plan) =~ ~r/^claude-code-linear-[0-9a-f]{4}$/
    end
  end

  describe "privileged profiles" do
    test "are applied after the checkpoint, and their secret never reaches the record", ctx do
      secrets = Path.join(ctx.tmp_dir, "secrets")
      File.mkdir_p!(secrets)
      File.write!(Path.join(secrets, "ANTHROPIC_API_KEY"), "sk-test-not-real\n")

      {sprites, log} = FakeSprites.start()
      assert {:ok, record} = Launcher.launch(["claude-code", "anthropic-key"], opts(ctx, sprites))

      env_writes =
        for {:write_file, [_, "/home/sprite/.config/profiled/env.sh", content, _]} <-
              FakeSprites.calls(log),
            do: content

      calls = Enum.map(FakeSprites.calls(log), &elem(&1, 0))
      checkpoint_at = Enum.find_index(calls, &(&1 == :checkpoint))

      assert [before, after_] = env_writes
      refute before =~ "ANTHROPIC_API_KEY"
      assert after_ =~ "export ANTHROPIC_API_KEY='sk-test-not-real'"

      last_env_write =
        FakeSprites.calls(log)
        |> Enum.with_index()
        |> Enum.filter(fn {{k, a}, _} -> k == :write_file and Enum.at(a, 1) =~ "env.sh" end)
        |> List.last()
        |> elem(1)

      assert last_env_write > checkpoint_at
      refute File.read!(record.record_path) =~ "sk-test-not-real"
    end
  end

  describe "labels and failures" do
    test "labels that do not stick at create are set again and verified", ctx do
      {sprites, log} =
        FakeSprites.start(fn
          {:create, [name, _]} -> {:ok, %{name: name, labels: [], url: nil}}
          {:get, [name]} -> {:ok, %{name: name, labels: ["profile:preview"], url: nil}}
          _ -> :default
        end)

      assert {:ok, record} = Launcher.launch(["preview"], opts(ctx, sprites))
      assert record.labels_via == "update"
      assert FakeSprites.calls(log, :set_labels) == [["demo-1", ["profile:preview"]]]
    end

    test "a failing setup stops the launch; the Sprite stays unless asked", ctx do
      fail = fn
        {:exec, [_, ["bash", "-c", s], _]} ->
          if s =~ "run-setup.sh\" ",
            do: {:ok, %{status: 1, output: "boom"}},
            else: :default

        _ ->
          :default
      end

      {sprites, log} = FakeSprites.start(fail)
      assert {:error, record} = Launcher.launch(["claude-code"], opts(ctx, sprites))
      assert record.outcome == :failed
      assert record.error.step == :setup
      assert record.error.message =~ "boom"
      assert FakeSprites.calls(log, :checkpoint) == []
      assert FakeSprites.calls(log, :destroy) == []

      {sprites, log} = FakeSprites.start(fail)

      assert {:error, record} =
               Launcher.launch(["claude-code"], opts(ctx, sprites, destroy_on_failure: true))

      assert FakeSprites.calls(log, :destroy) == [["demo-1"]]
      assert List.last(record.steps).step == :destroy
    end

    test "a failed create destroys nothing", ctx do
      {sprites, log} =
        FakeSprites.start(fn
          {:create, _} -> {:error, "limit reached"}
          _ -> :default
        end)

      assert {:error, record} =
               Launcher.launch(["preview"], opts(ctx, sprites, destroy_on_failure: true))

      assert record.error.message == "limit reached"
      assert FakeSprites.calls(log, :destroy) == []
    end
  end

  test "the default name is the picks and 4 hex digits" do
    {:ok, plan, _, _} = Launcher.resolve(["claude-code", "preview"])
    assert Launcher.default_name(plan) =~ ~r/^claude-code-preview-[0-9a-f]{4}$/
  end

  describe "inputs, a custom API connector and service env" do
    @echo """
    format  = 2
    name    = "echo"
    summary = "an echo API through a custom connector"

    [inputs.greeting]
    summary = "what to say"

    [env]
    ECHO_URL      = { from = "connector", provider = "custom_api" }
    ECHO_GREETING = { from = "input", name = "greeting" }

    [[connectors]]
    provider  = "custom_api"
    base_url  = "https://echo.example.com"
    endpoints = ["/anything/*"]

    [[services]]
    name = "echo"
    cmd  = "sleep"
    args = ["600"]
    """

    setup ctx do
      dir = Path.join(ctx.tmp_dir, "profiles")
      File.mkdir_p!(Path.join(dir, "echo"))
      File.write!(Path.join([dir, "echo", "profile.toml"]), @echo)
      File.mkdir_p!(Path.join(ctx.tmp_dir, "secrets"))
      File.write!(Path.join([ctx.tmp_dir, "secrets", "ANTHROPIC_API_KEY"]), "sk-test-not-real\n")

      connector = %{
        id: "conn_e",
        provider: "custom_api",
        name: "echo",
        allow_all: false,
        sprite_labels: ["profile:echo"],
        name_prefix: nil,
        allowed_endpoints: ["/anything/*"],
        blocked_endpoints: [],
        base_url: "https://echo.example.com"
      }

      %{dirs: [Path.expand("profiles"), dir], connector: connector}
    end

    defp launch_echo(ctx, respond, extra \\ []) do
      {sprites, log} = FakeSprites.start(respond)

      result =
        Launcher.launch(
          ["echo", "anthropic-key"],
          opts(ctx, sprites, [dirs: ctx.dirs, inputs: %{"greeting" => "kia ora"}] ++ extra)
        )

      {result, log}
    end

    test "the gateway URL and the input value reach the env file; the service gets its phase's env",
         ctx do
      {{:ok, record}, log} =
        launch_echo(ctx, fn
          {:list_connectors, []} -> {:ok, [ctx.connector]}
          _ -> :default
        end)

      assert record.outcome == :ok
      assert record.inputs == %{"greeting" => "kia ora"}
      assert record.connectors == ["custom_api echo"]

      envs =
        for [_, "/home/sprite/.config/profiled/env.sh", content, 0o600] <-
              FakeSprites.calls(log, :write_file),
            do: content

      [checkpointed, all] = envs

      assert checkpointed =~
               "export ECHO_URL='https://api.sprites.dev/v1/gateway/custom_api/conn_e'"

      assert checkpointed =~ "export ECHO_GREETING='kia ora'"
      refute checkpointed =~ "ANTHROPIC_API_KEY"
      assert all =~ "ANTHROPIC_API_KEY"

      [[_, "echo", spec]] = FakeSprites.calls(log, :put_service)

      assert spec.env == %{
               "ECHO_GREETING" => "kia ora",
               "ECHO_URL" => "https://api.sprites.dev/v1/gateway/custom_api/conn_e"
             }

      assert %{"env" => %{"ECHO_GREETING" => "kia ora"}} =
               SpriteProfiles.Sprites.Rest.service_body(spec)

      record_json = File.read!(record.record_path)
      assert record_json =~ ~s("greeting": "kia ora")
      refute record_json =~ "sk-test-not-real"
    end

    test "a missing required input is refused before any call", ctx do
      {sprites, log} = FakeSprites.start()

      assert {:error, [r]} =
               Launcher.launch(["echo"], opts(ctx, sprites, dirs: ctx.dirs))

      assert r.code == :input_missing
      assert FakeSprites.calls(log) == []
    end

    test "a connector that does not cover the endpoints refuses before create", ctx do
      narrowed = %{ctx.connector | allowed_endpoints: ["/get"]}

      {{:error, [r]}, log} =
        launch_echo(ctx, fn
          {:list_connectors, []} -> {:ok, [narrowed]}
          _ -> :default
        end)

      assert r.code == :connector_endpoints
      assert Enum.map(FakeSprites.calls(log), &elem(&1, 0)) == [:list_connectors]
    end
  end
end

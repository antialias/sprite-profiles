defmodule SpriteProfiles.CLICommandsTest do
  # The binary's commands beyond plan: show, search, add, remove, lock and launch from the
  # project file, connect, and the crash guard of run/0. GitHub is the Req.Test stub; the
  # cache is a temporary folder (SPRITE_PROFILES_CACHE), so these tests are not async.
  use ExUnit.Case

  import ExUnit.CaptureIO
  import SpriteProfiles.GitHubFixtures

  alias SpriteProfiles.{CLI, Commands, FakeSprites, ProjectFile}

  @profiles Path.expand("../../profiles", __DIR__)
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    saved = System.get_env("SPRITE_PROFILES_CACHE")
    System.put_env("SPRITE_PROFILES_CACHE", Path.join(tmp, "cache"))

    on_exit(fn ->
      if saved,
        do: System.put_env("SPRITE_PROFILES_CACHE", saved),
        else: System.delete_env("SPRITE_PROFILES_CACHE")
    end)

    project = Path.join(tmp, "project")
    File.mkdir_p!(project)
    {:ok, project: project}
  end

  defp run(argv, ctx \\ []) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:status, CLI.run_main(argv, ctx)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  ## show

  test "show prints what a local profile reaches, and how to connect and launch it" do
    {0, out, ""} = run(["show", "github-mcp", "--dir", @profiles])

    assert out =~ "github-mcp  (local, "
    assert out =~ "Reaches:     connector custom_api https://api.githubcopilot.com, Bearer header"
    assert out =~ "Network:     defaults; allows api.sprites.dev"
    assert out =~ "MCP servers: github (http, credential from the connector)"
    assert out =~ "GITHUB_MCP_URL (custom_api connector URL)"
    assert out =~ ~r/setup.sh:    none +privileged: no +files: 0/
    assert out =~ "Once per org:  sprite-profiles connect github-mcp"
    assert out =~ "Launch:        sprite-profiles launch claude-code github-mcp --name demo"
    refute out =~ "Checkpoint:"
  end

  test "show says when a profile is kept out of checkpoints" do
    {0, out, ""} = run(["show", "anthropic-key", "--dir", @profiles])

    assert out =~ ~r/privileged: yes/
    assert out =~ "Checkpoint:  applied after the launch's checkpoint, never saved in one"
  end

  test "show lists the Claude Code settings a profile grants" do
    {0, out, ""} = run(["show", "claude-code", "--dir", @profiles])

    assert out =~
             ~r/Claude:      hooks PreToolUse, Stop, UserPromptSubmit; sets env\.BASH_DEFAULT_TIMEOUT_MS/

    refute run(["show", "github-mcp", "--dir", @profiles]) |> elem(1) =~ "Claude:"
  end

  test "show resolves a name to its newest version" do
    stub_names()
    {0, out, ""} = run(["show", "@acme/linear"])

    assert out =~
             "@acme/linear 1.1.0  acme/sprite-profiles/linear@linear/v1.1.0 = c3c3c3c3\n"

    assert out =~ "Skills:      triage"
    assert out =~ "Launch:        sprite-profiles launch claude-code @acme/linear --name demo"
  end

  test "show refuses an unknown profile, and takes exactly one" do
    assert {1, "", "Refused:\n  [profile_not_found]" <> _} =
             run(["show", "nope", "--dir", @profiles])

    assert {2, "", err} = run(["show", "a", "b"])
    assert err =~ "name one profile"
  end

  test "touches/1 is the compact line search prints" do
    {:ok, [mcp, key, preview, claude]} =
      SpriteProfiles.Resolver.find(
        ~w(github-mcp anthropic-key preview claude-code),
        [@profiles]
      )

    assert Commands.Show.touches(mcp) ==
             "connector api.githubcopilot.com /mcp/, allows api.sprites.dev"

    assert Commands.Show.touches(key) == "privileged"
    assert Commands.Show.touches(preview) == "service preview:8080"
    assert Commands.Show.touches(claude) =~ ~r/^setup.sh 5m, allows .+, .+ \+\d+$/
  end

  ## search

  defp search_stub(search_answer) do
    test = self()
    repos = names_repos()

    Req.Test.stub(SpriteProfiles.GitHub, fn conn ->
      send(test, {:github, conn.host, conn.request_path, conn.req_headers})

      case {conn.host, String.split(conn.request_path, "/", trim: true)} do
        {"api.github.com", ["search", "repositories"]} ->
          search_answer.(Plug.Conn.fetch_query_params(conn))

        {"api.github.com", ["repos", "acme", "sprite-profiles", "git", "trees", "main"]} ->
          paths = repos["acme/sprite-profiles"].raw[sha("c1")] |> Map.keys()
          Req.Test.json(conn, %{"tree" => Enum.map(paths, &%{"path" => &1})})

        {"github.com", [owner, repo_git, "info", "refs"]} ->
          case repos["#{owner}/#{String.trim_trailing(repo_git, ".git")}"] do
            %{refs: refs} -> Plug.Conn.send_resp(conn, 200, advertisement(refs))
            _ -> Plug.Conn.send_resp(conn, 401, "")
          end

        {"raw.githubusercontent.com", [owner, repo, sha | path]} ->
          case get_in(repos, ["#{owner}/#{repo}", :raw, sha, Enum.join(path, "/")]) do
            nil -> Plug.Conn.send_resp(conn, 404, "404: Not Found")
            text -> Plug.Conn.send_resp(conn, 200, text)
          end

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  defp item(owner, name, stars),
    do: %{
      "name" => name,
      "owner" => %{"login" => owner},
      "stargazers_count" => stars,
      "default_branch" => "main"
    }

  test "search lists each repository's profiles with version, stars and summary" do
    search_stub(fn conn ->
      assert conn.query_params["q"] == "topic:sprite-profile linear tools"

      Req.Test.json(conn, %{
        "items" => [
          item("acme", "sprite-profile-solo", 12),
          item("acme", "sprite-profiles", 3),
          item("acme", "unconventional", 1)
        ]
      })
    end)

    {0, out, ""} = run(["search", "linear", "tools"], [])
    lines = String.split(out, "\n", trim: true)

    assert Enum.at(lines, 0) =~
             ~r/^@acme\/solo +1\.10\.0 +★12 +test profile solo · nothing beyond the defaults$/

    # The collection's folders, without solo/ (its own repository wins) and both/ (ambiguous).
    assert Enum.any?(lines, &(&1 =~ ~r/^@acme\/linear +1\.1\.0 +★3 +test profile linear/))
    assert Enum.any?(lines, &(&1 =~ ~r/^@acme\/plain +1\.1\.0 +★3 +test profile plain/))

    assert Enum.any?(
             lines,
             &(&1 =~ ~r/^@acme\/both +\? +★3 +\(cannot be resolved: .*two folders/)
           )

    assert Enum.count(lines, &String.starts_with?(&1, "@acme/solo")) == 1
    assert out =~ "not read: acme/unconventional"
    assert out =~ "See one in full with: sprite-profiles show @acme/solo"
  end

  test "search says clearly when nothing is published" do
    search_stub(fn conn -> Req.Test.json(conn, %{"items" => []}) end)
    {0, out, ""} = run(["search"])
    assert out =~ "No profiles are published yet"

    {0, out, ""} = run(["search", "zzz"])
    assert out =~ ~s(No published profile matches "zzz")
  end

  test "search reports a rate limit, and sends a token without printing it" do
    search_stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
      |> Plug.Conn.put_resp_header("retry-after", "42")
      |> Plug.Conn.send_resp(403, ~s({"message":"API rate limit exceeded"}))
    end)

    test = self()

    out = %SpriteProfiles.Out{
      info: &send(test, {:info, &1}),
      error: &send(test, {:error, &1}),
      usage: & &1
    }

    assert Commands.Search.run(["x"], [token: nil], out) == 1
    assert_received {:error, message}
    assert message =~ "rate limited"
    assert message =~ "10 searches a minute without a token"
    assert message =~ "Try again in 42 s."

    assert_received {:github, "api.github.com", _, headers}
    refute List.keymember?(headers, "authorization", 0)

    assert Commands.Search.run(["x"], [token: "tok-not-real"], out) == 1
    assert_received {:error, message}
    refute message =~ "tok-not-real"
    assert_received {:github, "api.github.com", _, headers}
    assert {"authorization", "Bearer tok-not-real"} in headers
  end

  ## the project file

  test "add writes names at their major version, replaces, and remove takes out",
       %{project: dir} do
    stub_names()
    file = Path.join(dir, "sprite-profiles.toml")

    {0, out, ""} = run(["add", "claude-code", "@acme/solo", "--dir", @profiles], cwd: dir)
    assert out =~ "Added claude-code  (local)"
    assert out =~ "Added @acme/solo@1  (1.10.0)"
    refute out =~ "sprite-profiles.toml:"
    assert File.read!(file) =~ ~s(profiles = ["claude-code", "@acme/solo@1"])
    assert File.read!(file) =~ "[inputs]"

    {0, out, ""} = run(["add", "@acme/solo@main", "@acme/linear"], cwd: dir)
    assert out =~ "Replaced @acme/solo@1 with @acme/solo@main"

    assert {:ok, %{profiles: ["claude-code", "@acme/solo@main", "@acme/linear@1"]}} =
             ProjectFile.read(file)

    {0, out, ""} = run(["remove", "@acme/solo"], cwd: dir)
    assert out == "Removed @acme/solo@main\n"
    assert {:ok, %{profiles: ["claude-code", "@acme/linear@1"]}} = ProjectFile.read(file)

    {1, _, err} = run(["remove", "github"], cwd: dir)
    assert err =~ "Not in sprite-profiles.toml: github"
    assert {:ok, %{profiles: ["claude-code", "@acme/linear@1"]}} = ProjectFile.read(file)
  end

  test "add refuses a pick that does not resolve, and writes nothing", %{project: dir} do
    assert {1, "", "Refused:" <> _} = run(["add", "nope", "--dir", @profiles], cwd: dir)
    refute File.exists?(Path.join(dir, "sprite-profiles.toml"))
  end

  test "plan, lock and launch --dry-run read the file and its inputs", %{project: dir} do
    File.write!(Path.join(dir, "sprite-profiles.toml"), """
    # my project
    profiles = ["claude-code", "github-mcp"]

    [inputs]
    readonly = "false"
    """)

    {0, out, ""} = run(["plan", "--dir", @profiles], cwd: dir)
    assert out =~ "Plan for claude-code+github-mcp"
    assert out =~ ~s(readonly = "false")

    {0, out, ""} = run(["plan", "--dir", @profiles, "-i", "readonly=true"], cwd: dir)
    assert out =~ ~s(readonly = "true")

    {0, out, ""} = run(["lock", "--dir", @profiles], cwd: dir)
    assert out =~ "Locked 2 picks in sprite-profiles.lock"
    lock = File.read!(Path.join(dir, "sprite-profiles.lock"))
    assert lock =~ ~s(readonly = "false")

    {0, out, ""} = run(["launch", "--dry-run", "--dir", @profiles], cwd: dir)
    assert out =~ "Dry run: nothing was created."

    assert {2, "", err} = run(["plan", "github", "--dir", @profiles], cwd: dir)
    assert err =~ "sprite-profiles.toml in this folder names the set"
  end

  test "no picks and no file is the same bad usage as the Mix task", %{project: dir} do
    assert {2, "", err} = run(["plan"], cwd: dir)
    assert err =~ "\nname at least one profile, or give --lock FILE\n"

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    assert catch_exit(Mix.Tasks.Profiles.Plan.run([])) == {:shutdown, 2}
    assert_received {:mix_shell, :error, [message]}
    assert message =~ "\nname at least one profile, or give --lock FILE"

    assert catch_exit(Mix.Tasks.Profiles.Lock.run([])) == {:shutdown, 2}
    assert {2, "", err} = run(["lock"], cwd: dir)
    assert err =~ "\nname at least one profile\n"
  end

  test "an edit keeps the file's comments and inputs" do
    text = "# ours\nprofiles = [\n  \"a-one\", # first\n]\n\n[inputs]\nx = \"1\"\n"
    new = ProjectFile.update(text, ["a-one", "b-two"])
    assert new =~ "# ours\n"
    assert new =~ ~s(profiles = ["a-one", "b-two"])

    assert {:ok, %{profiles: ["a-one", "b-two"], inputs: %{"x" => "1"}}} =
             ProjectFile.decode(new, "f")

    assert {:error, [%{code: :bad_project_file}]} = ProjectFile.decode("profile = []", "f")
  end

  ## connect, launch, the crash guard

  test "connect takes a positional pick and never shows the token" do
    {sprites, log} = FakeSprites.start()

    connect = [
      terminal?: fn -> true end,
      read_token: fn -> "dummy-token-in-test" end,
      sprites: sprites
    ]

    {0, out, err} = run(["connect", "github-mcp", "--dir", @profiles], connect: connect)
    assert out =~ "Connector:  github-mcp  (custom_api)"
    refute out <> err =~ "dummy-token-in-test"
    assert [[_body]] = FakeSprites.calls(log, :create_custom_connector)

    {1, _, err} =
      run(["connect", "github-mcp", "--dir", @profiles],
        connect: Keyword.put(connect, :terminal?, fn -> false end)
      )

    assert err =~ "[needs_terminal]"
  end

  test "a --verbose launch prints its steps and summary, and ends with the ✓ line",
       %{tmp_dir: tmp} do
    {sprites, _log} = FakeSprites.start()
    test = self()

    out = %SpriteProfiles.Out{
      info: &send(test, {:info, &1}),
      error: &send(test, {:error, &1}),
      usage: & &1
    }

    opts = [
      dirs: [@profiles],
      name: "demo-1",
      sprites: sprites,
      state_dir: Path.join(tmp, "launches"),
      verbose: true
    ]

    assert Commands.Launch.run(["preview"], opts, out) == 0
    lines = for {:info, l} <- Process.info(self(), :messages) |> elem(1), do: l
    assert hd(lines) == "Launching preview"
    assert Enum.any?(lines, &(&1 =~ "Sprite:     demo-1"))

    assert Enum.any?(lines, &(&1 =~ ~r/^  create +\d+\.\d\d s  labels set at create/))

    assert List.last(lines) =~
             ~r/^✓ demo-1: 1 profile · checkpointed · \d+\.\d s$/
  end

  test "a --verbose launch prints setup.sh's lines as they come, before its step line",
       %{tmp_dir: tmp} do
    respond = fn
      {:exec, [_, ["bash", "-c", s], opts]} ->
        if s =~ "run-setup.sh\" " do
          opts[:on_output].("Open https://example/device\nenter ")
          opts[:on_output].("\e[1mABCD-1234\e[0m\n")

          {:streamed,
           {:ok, %{status: 0, output: "Open https://example/device\nenter ABCD-1234\n"}}}
        else
          :default
        end

      _ ->
        :default
    end

    {sprites, _log} = FakeSprites.start(respond)
    test = self()

    out = %SpriteProfiles.Out{
      info: &send(test, {:info, &1}),
      error: &send(test, {:error, &1}),
      usage: & &1
    }

    opts = [
      dirs: [@profiles],
      name: "demo-1",
      sprites: sprites,
      state_dir: Path.join(tmp, "launches"),
      verbose: true
    ]

    assert Commands.Launch.run(["claude-code"], opts, out) == 0
    {:messages, messages} = Process.info(self(), :messages)
    refute Enum.any?(messages, &match?({:error, _}, &1))
    lines = for {:info, l} <- messages, do: l
    i = Enum.find_index(lines, &(&1 == "  setup claude-code | Open https://example/device"))
    assert i

    assert [
             "  setup claude-code | enter ABCD-1234",
             "  setup claude-code" <> step
           ] = Enum.slice(lines, i + 1, 2)

    assert step =~ ~r/^\s+\d+\.\d\d s  enter ABCD-1234$/
  end

  test "a failed setup.sh ends a --verbose launch with its error and how to destroy the Sprite",
       %{tmp_dir: tmp} do
    respond = fn
      {:exec, [_, ["bash", "-c", s], _opts]} ->
        if s =~ "run-setup.sh\" ",
          do: {:ok, %{status: 1, output: "the code expired\n"}},
          else: :default

      _ ->
        :default
    end

    {sprites, _log} = FakeSprites.start(respond)
    test = self()

    out = %SpriteProfiles.Out{
      info: &send(test, {:info, &1}),
      error: &send(test, {:error, &1}),
      usage: & &1
    }

    opts = [
      dirs: [@profiles],
      name: "demo-1",
      sprites: sprites,
      state_dir: Path.join(tmp, "l"),
      verbose: true
    ]

    assert Commands.Launch.run(["claude-code"], opts, out) == 1
    errors = for {:error, l} <- Process.info(self(), :messages) |> elem(1), do: l
    assert Enum.any?(errors, &(&1 =~ "Failed at setup claude-code"))
    assert Enum.any?(errors, &(&1 =~ "destroy it with: sprite destroy --force demo-1"))
  end

  ## the compact launch output, the default

  # A project profile beside the bundled ones, picked by path as `./weekend`.
  @weekend """
  name    = "weekend"
  summary = "A test project's task and permissions"

  [claude.settings.permissions]
  allow = ["Skill", "mcp__github", "Edit(~/site/**)"]
  """

  @connectors [
    %{
      id: "conn_a",
      provider: "custom_api",
      name: "anthropic",
      allow_all: false,
      sprite_labels: ["profile:anthropic"],
      name_prefix: nil,
      allowed_endpoints: ["/v1/*"],
      blocked_endpoints: [],
      base_url: "https://api.anthropic.com"
    },
    %{
      id: "conn_g",
      provider: "custom_api",
      name: "github-mcp",
      allow_all: false,
      sprite_labels: ["profile:github-mcp"],
      name_prefix: nil,
      allowed_endpoints: ["/mcp/"],
      blocked_endpoints: [],
      base_url: "https://api.githubcopilot.com"
    }
  ]

  # A fake launch through the command; returns {status, ops}, each op {:info | :error |
  # :write, text} in the order written. `setup` answers a profile's setup.sh run.
  defp compact_launch(picks, tmp, extra, setup \\ fn _p, _on_output -> :default end) do
    weekend = Path.join(tmp, "weekend")
    File.mkdir_p!(Path.join(weekend, "claude/skills/weekend-page"))
    File.write!(Path.join(weekend, "profile.toml"), @weekend)

    File.write!(
      Path.join(weekend, "claude/skills/weekend-page/SKILL.md"),
      "---\nname: weekend-page\ndescription: Build the weekend page.\n---\n\nBuild it.\n"
    )

    respond = fn
      {:list_connectors, []} ->
        {:ok, @connectors}

      {:exec, [_, ["bash", "-c", s], opts]} ->
        case Regex.run(~r/run-setup\.sh" '([^']+)'/, s) do
          [_, p] -> setup.(p, opts[:on_output])
          nil -> :default
        end

      _ ->
        :default
    end

    {sprites, _log} = FakeSprites.start(respond)
    test = self()

    out = %SpriteProfiles.Out{
      info: &send(test, {:op, {:info, &1}}),
      error: &send(test, {:op, {:error, &1}}),
      write: &send(test, {:op, {:write, &1}}),
      usage: & &1
    }

    opts =
      Keyword.merge(
        [
          dirs: [@profiles],
          set_opts: [base: tmp],
          name: "demo",
          sprites: sprites,
          state_dir: Path.join(tmp, "launches"),
          terminal?: fn -> false end
        ],
        extra
      )

    status = Commands.Launch.run(picks, opts, out)
    {status, ops()}
  end

  # The ops written so far, taken out of the mailbox.
  defp ops do
    receive do
      {:op, op} -> [op | ops()]
    after
      0 -> []
    end
  end

  @seven ~w(claude-code anthropic github-mcp playwright preview ./weekend)

  test "a launch prints a line for the Sprite, one per profile, and the last line with the URL",
       %{tmp_dir: tmp} do
    {0, ops} = compact_launch(@seven, tmp, [])
    lines = for {:info, l} <- ops, do: l
    assert for({kind, _} <- ops, kind != :info, do: kind) == []

    # Every line but the last two is "✓ <pick, padded> <time> s  <what it added>".
    shape = ~r/^✓ (\S+(?: \S+)?) +\d+\.\d s  (.+)$/
    # The fake's setup.sh prints "ok": shown, indented, before its profile's line.
    assert Enum.count(lines, &(&1 == "    ok")) == 2
    rows = for l <- Enum.drop(lines, -2), l != "    ok", do: tl(Regex.run(shape, l))

    assert rows == [
             ["Sprite demo", "2 connectors admitted · network policy · 6 env vars"],
             ["claude-code", "setup · MCP context7 · hooks · 1 setting · 1 skill · 1 file"],
             ["anthropic", "connector api.anthropic.com"],
             ["github-mcp", "connector api.githubcopilot.com · MCP github · 1 skill"],
             ["playwright", "setup · 1 file"],
             ["preview", "service preview :8080 · 1 file"],
             ["./weekend", "3 permissions · 1 skill"]
           ]

    # one column for the times, every line under 100 columns
    assert lines
           |> Enum.drop(-2)
           |> Enum.reject(&(&1 == "    ok"))
           |> Enum.map(&:binary.match(&1, " s  "))
           |> Enum.uniq()
           |> length() == 1

    assert Enum.all?(lines, &(String.length(&1) < 100))

    assert [done, "  url"] = Enum.take(lines, -2)
    assert done =~ ~r/^✓ demo: 6 profiles · checkpointed · \d+\.\d s$/
    refute Enum.any?(lines, &(&1 =~ ~r/^(Launching|Sources:|Sprite: )/))
  end

  test "setup.sh's output shows while it runs: a region erased on a terminal, plain lines elsewhere",
       %{tmp_dir: tmp} do
    setup = fn
      "claude-code", on_output ->
        on_output.("Open https://example/device\nenter ")
        on_output.("\e[1mABCD-1234\e[0m\n")
        {:streamed, {:ok, %{status: 0, output: "Open https://example/device\nenter ABCD-1234\n"}}}

      _, _ ->
        :default
    end

    {0, piped} = compact_launch(["claude-code", "preview"], tmp, [], setup)
    texts = Enum.map(piped, &elem(&1, 1))
    i = Enum.find_index(texts, &(&1 == "    Open https://example/device"))
    assert ["    enter ABCD-1234", "✓ claude-code" <> _] = Enum.slice(texts, i + 1, 2)
    refute Enum.any?(texts, &(&1 =~ "\e"))

    {0, tty} =
      compact_launch(
        ["claude-code", "preview"],
        tmp,
        [terminal?: fn -> true end, columns: 80],
        setup
      )

    erase = "\e[1A\e[2K"
    i = Enum.find_index(tty, &match?({:info, "✓ claude-code" <> _}, &1))

    assert [
             {:info,
              "… claude-code\n\e[2m    Open https://example/device\e[0m\n\e[2m    enter ABCD-1234\e[0m"},
             {:write, ^erase <> ^erase <> ^erase}
           ] = Enum.slice(tty, i - 2, 2)

    assert {:info, "… Sprite demo"} = hd(tty)
    refute Enum.any?(tty, fn {_, t} -> t =~ "\e[J" or t =~ "\e[0J" end)
  end

  test "a failed setup.sh: the ✗ line, its output, and how to destroy the Sprite",
       %{tmp_dir: tmp} do
    setup = fn
      "claude-code", on_output ->
        on_output.("Waiting for sign-in\nthe code expired\n")
        {:streamed, {:ok, %{status: 1, output: "Waiting for sign-in\nthe code expired\n"}}}

      _, _ ->
        :default
    end

    {1, ops} = compact_launch(["claude-code", "preview"], tmp, [terminal?: fn -> true end], setup)
    errors = for {:error, l} <- ops, do: l

    assert [
             "✗ claude-code" <> failed,
             "    Waiting for sign-in",
             "    the code expired",
             "The Sprite demo was left as it is; destroy it with: sprite destroy --force demo"
           ] = errors

    assert failed =~ ~r/^ +\d+\.\d s  setup\.sh exited 1$/
    refute Enum.any?(ops, &match?({:info, "✓ claude-code" <> _}, &1))
    refute Enum.any?(ops, &match?({:info, "✓ demo" <> _}, &1))
  end

  test "the Task hold line is gone from setup.sh's output, in every mode" do
    script = SpriteProfiles.Launcher.runner_script()
    refute script =~ "Task hold:"
    assert script =~ ~s(hold >/dev/null 2>&1\n)
  end

  ## exec

  defp exec(argv, answer) do
    test = self()

    respond = fn
      {:exec, [_name, argv, opts]} ->
        send(test, {:argv, argv})
        answer.(opts[:on_output])

      _ ->
        :default
    end

    {sprites, _log} = FakeSprites.start(respond)
    run(["exec" | argv], exec: [sprites: sprites])
  end

  test "exec runs the command in a login shell, each argument quoted as it is" do
    {0, "", ""} =
      exec(["demo", "claude", "-p", ~s(Build the "weekend" page, it's due.)], fn _ ->
        {:ok, %{status: 0, output: ""}}
      end)

    assert_received {:argv, ["bash", "-lc", script]}
    assert script == ~S('claude' '-p' 'Build the "weekend" page, it'\''s due.')

    {0, "", ""} =
      exec(["demo", "--", "ls", "--", "-la"], fn _ -> {:ok, %{status: 0, output: ""}} end)

    assert_received {:argv, ["bash", "-lc", "'ls' '--' '-la'"]}
  end

  test "exec streams the output without the image's bind warnings, and passes the status on" do
    bind = "/home/sprite/.bashrc: line 22: bind: warning: line editing not enabled"

    {3, out, ""} =
      exec(["demo", "sh", "-c", "exit 3"], fn on_output ->
        on_output.(bind <> "\n/home/sprite/.bashrc: line 23: bind: warn")
        on_output.("ing: line editing not enabled\nfirst line\nbind: warning: line editing")
        on_output.(" not enabled\nlast, no newline")
        {:streamed, {:ok, %{status: 3, output: "…"}}}
      end)

    assert out ==
             "first line\nbind: warning: line editing not enabled\nlast, no newline"
  end

  test "exec without a command is bad usage" do
    {2, "", err} = run(["exec", "demo"])
    assert err =~ "usage: sprite-profiles exec"
    assert err =~ "name the command to run"
    {2, "", _} = run(["exec"])
    {0, help, ""} = run(["help", "exec"])
    assert help =~ "bash -lc"
  end

  test "the launch summary ends with one line for a recording" do
    record = %{
      name: "demo",
      profiles: ~w(a b c d),
      connectors: ~w(x y),
      checkpoint: "v1",
      total_ms: 14_230
    }

    assert Commands.Launch.done_line(record) ==
             "✓ demo: 4 profiles · checkpointed · 14.2 s"

    assert Commands.Launch.done_line(%{
             record
             | profiles: ["a"],
               connectors: ["x"],
               checkpoint: nil
           }) ==
             "✓ demo: 1 profile · not checkpointed · 14.2 s"
  end

  test "an exception is one line and status 70, not a crashed VM", %{tmp_dir: tmp} do
    stub_acme()
    blocker = Path.join(tmp, "a-file")
    File.write!(blocker, "")
    System.put_env("SPRITE_PROFILES_CACHE", Path.join(blocker, "cache"))

    {70, "", err} = run(["plan", "acme/profiles/linear@v1"])
    assert err =~ ~r/^sprite-profiles: could not make directory .*\n$/
  end
end

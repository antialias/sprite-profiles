defmodule SpriteProfiles.MergeTest do
  # One describe block per row of the merge-rules table in docs/SPEC.md.
  use ExUnit.Case, async: true

  import SpriteProfiles.ProfileHelpers

  alias SpriteProfiles.{Merge, Plan, Profile}

  defp merge!(profiles, opts \\ []) do
    {:ok, plan} = Merge.merge(profiles, opts)
    plan
  end

  defp refusals(profiles, opts \\ []) do
    {:error, refusals} = Merge.merge(profiles, opts)
    refusals
  end

  describe "env" do
    test "keys from different profiles are united, each remembering its profile" do
      plan = merge!([profile!("aa", ~s([env]\nA = "1")), profile!("bb", ~s([env]\nB = "2"))])

      assert plan.env == %{
               "A" => %{value: "1", profile: "aa"},
               "B" => %{value: "2", profile: "bb"}
             }
    end

    test "a key two profiles define is env_collision, even with the same value" do
      [r] =
        refusals([
          profile!("github", ~s([env]\nGITHUB_TOKEN = "x")),
          profile!("claude-code", ~s([env]\nGITHUB_TOKEN = "x"))
        ])

      assert r.code == :env_collision
      assert r.profiles == ["github", "claude-code"]

      assert r.message ==
               "profiles 'github' and 'claude-code' both define env GITHUB_TOKEN; a set will not pick one silently, so remove it from one of them."
    end
  end

  describe "policy.rules" do
    test "no profile declares a policy: none is set" do
      assert merge!([profile!("aa"), profile!("bb")]).policy == nil
    end

    test "one profile declares a policy: it is set, though others declare none" do
      plan =
        merge!([profile!("aa"), profile!("bb", ~s([policy]\nrules = [{ include = "defaults" }]))])

      assert plan.policy == [:defaults]
    end

    test "union, deduplicated, defaults once, every deny before every allow" do
      plan =
        merge!([
          profile!("aa", """
          [policy]
          rules = [ { include = "defaults" }, { action = "allow", domain = "a.com" } ]
          """),
          profile!("bb", """
          [policy]
          rules = [ { action = "allow", domain = "a.com" }, { include = "defaults" },
                    { action = "deny", domain = "a.com" }, { action = "allow", domain = "b.com" } ]
          """)
        ])

      assert plan.policy == [{:deny, "a.com"}, :defaults, {:allow, "a.com"}, {:allow, "b.com"}]

      assert Plan.policy_json(plan) == %{
               "rules" => [
                 %{"action" => "deny", "domain" => "a.com"},
                 %{"include" => "defaults"},
                 %{"action" => "allow", "domain" => "a.com"},
                 %{"action" => "allow", "domain" => "b.com"}
               ]
             }
    end
  end

  describe "connectors" do
    setup do
      gh =
        ~s([[connectors]]\nprovider = "github"\n[env]\nG = { from = "connector", provider = "github" })

      gh2 = ~s([[connectors]]\nprovider = "github"\n[[connectors]]\nprovider = "slack")
      %{plan: merge!([profile!("github", gh), profile!("ci", gh2)])}
    end

    test "union by provider, remembering every profile that needs it", %{plan: plan} do
      assert plan.connectors == [
               %{provider: "github", profiles: ["github", "ci"]},
               %{provider: "slack", profiles: ["ci"]}
             ]
    end

    test "a connector whose policy admits one of the Sprite's labels passes", %{plan: plan} do
      available = [
        %{provider: "github", sprite_labels: ["profile:github"]},
        %{provider: "slack", allow_all: true}
      ]

      assert Merge.check_connectors(plan, available) == :ok
    end

    test "missing, or present but not admitting the labels, is connector_missing", %{plan: plan} do
      available = [%{provider: "github", sprite_labels: ["profile:other"]}]

      {:error, [gh, slack]} =
        Merge.check_connectors(plan, available, %{"slack" => "https://example.com/setup/slack"})

      assert gh.code == :connector_missing

      assert gh.message ==
               "profiles 'github' and 'ci' need a github connector that admits Sprites labelled profile:github or profile:ci, and the org has none; set one up in the Sprites dashboard and add that label to its access policy."

      assert slack.message =~ "profile 'ci' needs a slack connector"
      assert slack.message =~ "set one up at https://example.com/setup/slack"
    end
  end

  describe "labels" do
    test "profile:<name> for every pick, in order, then declared labels, deduplicated" do
      plan =
        merge!([
          profile!("aa", ~s(labels = ["team"])),
          profile!("bb", ~s(labels = ["team", "x"]))
        ])

      assert plan.labels == ["profile:aa", "profile:bb", "team", "x"]
    end
  end

  describe "services" do
    @svc ~s([[services]]\nname = "web"\ncmd = "x")

    test "union across profiles" do
      plan =
        merge!([profile!("aa", @svc), profile!("bb", ~s([[services]]\nname = "db"\ncmd = "y"))])

      assert Enum.map(plan.services, &{&1.name, &1.profile}) == [{"web", "aa"}, {"db", "bb"}]
    end

    test "the same name twice is service_collision" do
      [r] = refusals([profile!("aa", @svc), profile!("bb", @svc)])
      assert r.code == :service_collision
      assert r.message =~ "profiles 'aa' and 'bb' both define service 'web'"
    end

    test "two services with http_port is http_port_conflict, naming both" do
      [r] =
        refusals([
          profile!("preview", @svc <> "\nhttp_port = 8080"),
          profile!("docs", ~s([[services]]\nname = "docs"\ncmd = "y"\nhttp_port = 3000))
        ])

      assert r.code == :http_port_conflict

      assert r.message ==
               "profiles 'preview' and 'docs' both give a service an http_port ('web' on 8080, 'docs' on 3000); a Sprite routes its URL to one service, so drop http_port from one of them."
    end
  end

  describe "claude.mcp_servers" do
    @open ~s([claude.mcp_servers.docs]\ntype = "http"\nurl = "https://d.example.com"\nauth = "none")

    test "union across profiles" do
      plan =
        merge!([
          profile!("aa", @open),
          profile!("bb", ~s([claude.mcp_servers.tool]\ncommand = "tool"))
        ])

      assert Enum.map(plan.mcp_servers, &{&1.name, &1.type, &1.profile}) == [
               {"docs", "http", "aa"},
               {"tool", "stdio", "bb"}
             ]
    end

    test "the same name twice is mcp_server_collision" do
      [r] = refusals([profile!("aa", @open), profile!("bb", @open)])
      assert r.code == :mcp_server_collision
      assert r.message =~ "profiles 'aa' and 'bb' both define MCP server 'docs'"
    end

    test "an http server with no Authorization and no auth = none is mcp_needs_login" do
      [r] =
        refusals([profile!("aa", ~s([claude.mcp_servers.x]\ntype = "http"\nurl = "https://x"))])

      assert r.code == :mcp_needs_login
      assert r.message =~ "profile 'aa' adds http MCP server 'x' with no Authorization header"
    end

    test "an Authorization header whose env the set provides is fine; one it lacks refuses" do
      server = """
      [claude.mcp_servers.x]
      type = "http"
      url = "https://x"
      headers = { Authorization = "Bearer ${X_TOKEN}" }
      """

      [r] = refusals([profile!("aa", server)])
      assert r.code == :mcp_needs_login
      assert r.message =~ "needs env X_TOKEN, and no profile in the set defines it"

      key = profile!("key", ~s(privileged = true\n[env]\nX_TOKEN = { secret = "X_TOKEN" }))
      assert %Plan{} = merge!([profile!("aa", server), key])
    end

    test "a stdio server needing env the set does not provide is mcp_needs_login" do
      tool = ~s([claude.mcp_servers.tool]\ncommand = "tool"\nrequires_env = ["TOOL_KEY"])
      [r] = refusals([profile!("aa", tool)])
      assert r.code == :mcp_needs_login
      assert merge!([profile!("aa", tool), profile!("bb", ~s([env]\nTOOL_KEY = "k"))])
    end
  end

  describe "claude.settings and skills" do
    test "settings deep-merge; the same leaf with the same value is fine" do
      plan =
        merge!([
          profile!("aa", ~s([claude.settings.env]\nA = "1"\nSHARED = "s")),
          profile!(
            "bb",
            ~s([claude.settings]\nmodel = "m"\n[claude.settings.env]\nB = "2"\nSHARED = "s")
          )
        ])

      assert plan.claude_settings == %{
               "env" => %{"A" => "1", "B" => "2", "SHARED" => "s"},
               "model" => "m"
             }
    end

    test "a leaf two profiles set differently is settings_collision" do
      [r] =
        refusals([
          profile!("aa", ~s([claude.settings.env]\nBASH_DEFAULT_TIMEOUT_MS = "1")),
          profile!("bb", ~s([claude.settings.env]\nBASH_DEFAULT_TIMEOUT_MS = "2"))
        ])

      assert r.code == :settings_collision

      assert r.message ==
               "profiles 'aa' and 'bb' both set Claude setting env.BASH_DEFAULT_TIMEOUT_MS, to different values; a set will not pick one silently, so remove it from one of them."
    end

    test "a leaf in one profile that is a table in another is settings_collision" do
      [r] =
        refusals([
          profile!("aa", ~s([claude.settings]\nenv = "flat")),
          profile!("bb", ~s([claude.settings.env]\nX = "1"))
        ])

      assert r.code == :settings_collision
    end

    test "skills are namespaced by profile, so same-named skills never collide" do
      skill = [%{name: "howto", source: nil, files: ["SKILL.md"]}]
      plan = merge!([profile!("aa", "", skills: skill), profile!("bb", "", skills: skill)])

      assert Enum.map(plan.skills, & &1.dest) == [
               ".claude/skills/aa--howto/",
               ".claude/skills/bb--howto/"
             ]
    end
  end

  describe "files/" do
    defp files(paths), do: Enum.map(paths, &%{source: nil, path: &1, executable: false})

    test "pushed in pick order" do
      plan =
        merge!([
          profile!("aa", "", files: files(["b.txt"])),
          profile!("bb", "", files: files(["a.txt"]))
        ])

      assert Enum.map(plan.files, &{&1.dest, &1.profile}) == [{"b.txt", "aa"}, {"a.txt", "bb"}]
    end

    test "the same path from two profiles is file_collision; shared folders are fine" do
      [r] =
        refusals([
          profile!("aa", "", files: files([".config/x/a", ".bashrc"])),
          profile!("bb", "", files: files([".config/x/b", ".bashrc"]))
        ])

      assert r.code == :file_collision

      assert r.message ==
               "profiles 'aa' and 'bb' both push ~/.bashrc; a set will not pick one silently, so remove it from one of them."
    end

    test "a file in one profile where another has a folder is file_collision" do
      [r] =
        refusals([
          profile!("aa", "", files: files([".config/x"])),
          profile!("bb", "", files: files([".config/x/y"]))
        ])

      assert r.code == :file_collision
    end

    test "a file pushed into another profile's skill folder is file_collision" do
      skill = [%{name: "howto", source: nil, files: ["SKILL.md"]}]

      [r] =
        refusals([
          profile!("aa", "", skills: skill),
          profile!("bb", "", files: files([".claude/skills/aa--howto/SKILL.md"]))
        ])

      assert r.code == :file_collision
    end
  end

  describe "setup.sh" do
    test "runs in pick order, each with its profile's timeout; profiles without one are skipped" do
      plan =
        merge!([
          profile!("cc", ~s(timeout = "1m"), setup: "/p/cc/setup.sh"),
          profile!("aa"),
          profile!("bb", ~s(timeout = "20m"), setup: "/p/bb/setup.sh")
        ])

      assert plan.setup == [
               %{profile: "cc", script: "/p/cc/setup.sh", timeout: 60},
               %{profile: "bb", script: "/p/bb/setup.sh", timeout: 1200}
             ]
    end
  end

  describe "privileged" do
    setup do
      %{key: profile!("key", ~s(privileged = true\n[env]\nK = { secret = "K" }))}
    end

    test "a set holding a privileged profile is privileged; a person may launch it", %{key: key} do
      plan = merge!([profile!("aa"), key])
      assert plan.privileged
      refute merge!([profile!("aa")]).privileged
    end

    test "an agent is refused it with not_for_agents", %{key: key} do
      [r] = refusals([profile!("aa"), key], caller: :agent)
      assert r.code == :not_for_agents
      assert r.message =~ "profile 'key' is privileged; an agent may not launch"
      assert %Plan{} = merge!([profile!("aa")], caller: :agent)
    end
  end

  describe "order" do
    test "pick order, except privileged profiles go after the checkpoint", %{} do
      key = profile!("key", "privileged = true", setup: "/k.sh")

      plan =
        merge!([profile!("aa", "", setup: "/a.sh"), key, profile!("bb", "", setup: "/b.sh")])

      assert plan.before_checkpoint == ["aa", "bb"]
      assert plan.after_checkpoint == ["key"]
      assert Enum.map(plan.setup, & &1.profile) == ["aa", "bb", "key"]
      assert plan.set == "aa+key+bb"
    end

    test "checkpoint = false defers a public profile too" do
      plan = merge!([profile!("aa", "checkpoint = false"), profile!("bb")])
      assert {plan.before_checkpoint, plan.after_checkpoint} == {["bb"], ["aa"]}
    end

    test "the printed plan shows the final order around the checkpoint" do
      key = profile!("key", "privileged = true")
      text = Plan.format(merge!([key, profile!("aa")]))
      assert text =~ ~r/1\. aa\n.*checkpoint "profiled: key\+aa".*\n  2\. key/
    end
  end

  describe "bounds" do
    test "at most 8 picks" do
      ok = for i <- 1..8, do: profile!("p#{i}")
      assert %Plan{} = merge!(ok)
      [r] = refusals(ok ++ [profile!("p9")])
      assert r.code == :too_many_profiles
    end

    test "none repeated" do
      [r] = refusals([profile!("aa"), profile!("bb"), profile!("aa")])
      assert r.code == :duplicate_pick
      assert r.message == "profile 'aa' is picked 2 times; pick each profile once."
    end

    test "at least one" do
      assert {:error, [%{code: :no_profiles}]} = Merge.merge([])
    end

    test "names are checked before any profile is read" do
      {:error, refusals} = Merge.check_picks(["Good", "ok", "x"])
      assert codes(refusals) == [:bad_name, :bad_name]
    end
  end
end

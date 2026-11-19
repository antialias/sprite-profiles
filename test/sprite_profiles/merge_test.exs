defmodule SpriteProfiles.MergeTest do
  # One describe block per row of the merge-rules table in docs/SPEC.md.
  use ExUnit.Case, async: true

  import SpriteProfiles.ProfileHelpers

  alias SpriteProfiles.{Merge, Plan}

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
               %{provider: "github", name: nil, profiles: ["github", "ci"]},
               %{provider: "slack", name: nil, profiles: ["ci"]}
             ]
    end

    test "a connector whose policy admits one of the Sprite's labels passes", %{plan: plan} do
      available = [
        %{provider: "github", sprite_labels: ["profile:github"]},
        %{provider: "slack", allow_all: true}
      ]

      assert Merge.check_connectors(plan, available) == :ok
    end

    test "a policy admits only when the Sprite carries all its labels and matches its prefix" do
      labels = ["profile:github", "team:a"]

      assert Merge.admits?(%{sprite_labels: ["profile:github", "team:a"]}, labels, "x")
      refute Merge.admits?(%{sprite_labels: ["profile:github", "team:b"]}, labels, "x")
      assert Merge.admits?(%{name_prefix: "sp-"}, labels, "sp-1")
      refute Merge.admits?(%{name_prefix: "sp-"}, labels, "other")
      refute Merge.admits?(%{name_prefix: "sp-"}, labels, nil)
      refute Merge.admits?(%{sprite_labels: ["profile:github"], name_prefix: "sp-"}, labels, "x")
      assert Merge.admits?(%{allow_all: true, sprite_labels: ["nope"]}, labels, "x")
      refute Merge.admits?(%{sprite_labels: [], name_prefix: nil}, labels, "x")
    end

    test "check_connectors uses the Sprite's name for a prefix policy", %{plan: plan} do
      available = [
        %{provider: "github", name_prefix: "ci-"},
        %{provider: "slack", allow_all: true}
      ]

      assert Merge.check_connectors(plan, available, %{}, name: "ci-1") == :ok
      assert {:error, [_]} = Merge.check_connectors(plan, available, %{}, name: "dev-1")
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

    test "hooks arrays combine in pick order, each profile's entries kept whole" do
      plan =
        merge!([
          profile!("aa", """
          [[claude.settings.hooks.Stop]]
          hooks = [ { type = "command", command = "a-stop" } ]
          [[claude.settings.hooks.PreToolUse]]
          matcher = "Bash"
          hooks = [ { type = "command", command = "a-1" }, { type = "command", command = "a-2" } ]
          """),
          profile!("bb", """
          [[claude.settings.hooks.PreToolUse]]
          hooks = [ { type = "command", command = "b-1" } ]
          """)
        ])

      assert plan.claude_settings["hooks"]["PreToolUse"] == [
               %{
                 "matcher" => "Bash",
                 "hooks" => [
                   %{"type" => "command", "command" => "a-1"},
                   %{"type" => "command", "command" => "a-2"}
                 ]
               },
               %{"hooks" => [%{"type" => "command", "command" => "b-1"}]}
             ]

      assert plan.claude_settings["hooks"]["Stop"] == [
               %{"hooks" => [%{"type" => "command", "command" => "a-stop"}]}
             ]
    end

    test "an identical hook entry from two profiles is kept once" do
      hook = """
      [[claude.settings.hooks.Stop]]
      hooks = [ { type = "command", command = "same" } ]
      """

      plan = merge!([profile!("aa", hook), profile!("bb", hook)])

      assert plan.claude_settings["hooks"]["Stop"] == [
               %{"hooks" => [%{"type" => "command", "command" => "same"}]}
             ]
    end

    test "permissions.allow and deny combine and deduplicate; other lists stay leaves" do
      plan =
        merge!([
          profile!(
            "aa",
            ~s|[claude.settings.permissions]\nallow = ["Bash(ls)", "Read"]\ndeny = ["WebFetch"]|
          ),
          profile!("bb", ~s|[claude.settings.permissions]\nallow = ["Read", "Bash(git *)"]|)
        ])

      assert plan.claude_settings["permissions"] == %{
               "allow" => ["Bash(ls)", "Read", "Bash(git *)"],
               "deny" => ["WebFetch"]
             }

      [r] =
        refusals([
          profile!("aa", ~s([claude.settings.permissions]\nadditionalDirectories = ["/a"])),
          profile!("bb", ~s([claude.settings.permissions]\nadditionalDirectories = ["/b"]))
        ])

      assert r.code == :settings_collision
    end

    test "a scalar beside the combining lists keeps the collision rule" do
      [r] =
        refusals([
          profile!(
            "aa",
            ~s([claude.settings.permissions]\nallow = ["Read"]\ndefaultMode = "plan")
          ),
          profile!(
            "bb",
            ~s([claude.settings.permissions]\nallow = ["Read"]\ndefaultMode = "acceptEdits")
          )
        ])

      assert r.code == :settings_collision
      assert r.message =~ "permissions.defaultMode"
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

  describe "picks by address" do
    defp fetched(name, owner, pick, toml \\ "") do
      %{profile!(name, toml) | qualified: "#{owner}.#{name}", pick: pick}
    end

    test "check_picks takes names and addresses, and refuses bad ones with a code" do
      assert Merge.check_picks(["claude-code", "acme/profiles/linear@v1"]) == :ok

      {:error, rs} =
        Merge.check_picks(["acme/profiles/linear", "acme@v1", "gitlab.example/a/b@v1", "Bad"])

      assert codes(rs) == [:address_needs_ref, :bad_address, :bad_address, :bad_name]
      assert hd(rs).message =~ "acme/profiles/linear@v1 or acme/profiles/linear@main"
    end

    test "one address at two refs is a duplicate_pick" do
      {:error, [r]} = Merge.check_picks(["acme/profiles/linear@v1", "Acme/profiles/linear@v2"])
      assert r.code == :duplicate_pick
      assert r.profiles == ["acme/profiles/linear@v1", "Acme/profiles/linear@v2"]
      assert r.message =~ "(acme/profiles/linear)"
    end

    test "labels, identity and the set string use qualified names and picks" do
      plan =
        merge!([
          profile!("claude-code"),
          fetched("linear", "acme", "acme/profiles/linear@v1")
        ])

      assert plan.labels == ["profile:claude-code", "profile:acme.linear"]
      assert plan.profiles == ["claude-code", "acme.linear"]
      assert plan.set == "claude-code+acme/profiles/linear@v1"
    end

    test "a refusal sentence names the pick as written" do
      [r] =
        refusals([
          profile!("claude-code", ~s([env]\nLINEAR_URL = "a")),
          fetched("linear", "acme", "acme/profiles/linear@v1", ~s([env]\nLINEAR_URL = "b"))
        ])

      assert r.code == :env_collision
      assert r.profiles == ["claude-code", "acme/profiles/linear@v1"]

      assert r.message =~
               "profiles 'claude-code' and 'acme/profiles/linear@v1' both define env LINEAR_URL"
    end

    test "connector_missing names the dotted label and the pick" do
      plan =
        merge!([
          fetched(
            "linear",
            "acme",
            "acme/profiles/linear@v1",
            ~s([[connectors]]\nprovider = "linear")
          )
        ])

      {:error, [r]} = Merge.check_connectors(plan, [])
      assert r.profiles == ["acme/profiles/linear@v1"]

      assert r.message =~
               "profile 'acme/profiles/linear@v1' needs a linear connector that admits Sprites labelled profile:acme.linear"
    end

    test "a label longer than a Sprite takes is label_too_long" do
      # A GitHub owner is at most 39 characters, so a real address can't reach the limit.
      long = String.duplicate("o", 125)
      [r] = refusals([fetched("linear", long, "o/p/linear@v1")])
      assert r.code == :label_too_long
      assert r.message =~ "a Sprite takes labels of up to 128"
    end

    test "skills land under the qualified name" do
      p = %{
        fetched("linear", "acme", "acme/p/linear@v1")
        | skills: [%{name: "triage", source: nil, files: ["SKILL.md"]}]
      }

      plan = merge!([p])

      assert [%{dest: ".claude/skills/acme.linear--triage/", profile: "acme.linear"}] =
               plan.skills
    end
  end

  ## format 2

  @input_toml """
  format = 2
  [inputs.mode]
  summary = "fast or slow"
  default = "fast"
  pattern = '^(fast|slow)$'
  [env]
  MODE = { from = "input", name = "mode" }
  """

  @required_toml """
  format = 2
  [inputs.repo]
  summary = "the repository"
  [env]
  REPO = { from = "input", name = "repo" }
  """

  defp custom_toml(base \\ "https://api.example.com", endpoints \\ ~s(["/v1/*"])) do
    """
    format = 2
    [[connectors]]
    provider  = "custom_api"
    base_url  = "#{base}"
    endpoints = #{endpoints}
    [env]
    API_URL = { from = "connector", provider = "custom_api" }
    """
  end

  describe "inputs" do
    test "a default applies, and the plan says so" do
      plan = merge!([profile!("aa", @input_toml)])
      assert plan.env["MODE"] == %{value: "fast", profile: "aa"}
      assert plan.inputs == [%{name: "mode", value: "fast", default: true, profile: "aa"}]
      assert Plan.format(plan) =~ ~s<Inputs:\n  mode = "fast" (default)  (aa)>
      assert Plan.format(plan) =~ ~s<MODE = "fast"  (aa)>
    end

    test "a given value wins over the default" do
      plan = merge!([profile!("aa", @input_toml)], inputs: %{"mode" => "slow"})
      assert plan.env["MODE"].value == "slow"
      assert [%{value: "slow", default: false}] = plan.inputs
      refute Plan.format(plan) =~ "(default)"
    end

    test "a name two profiles declare is input_collision" do
      other = String.replace(@input_toml, "MODE =", "OTHER_MODE =")
      [r] = refusals([profile!("aa", @input_toml), profile!("bb", other)])
      assert r.code == :input_collision
      assert r.message =~ "profiles 'aa' and 'bb' both declare input mode"
    end

    test "a required input with no value is input_missing, naming -i" do
      [r] = refusals([profile!("aa", @required_toml)])
      assert r.code == :input_missing
      assert r.message =~ "-i repo=VALUE"
    end

    test "a value failing the pattern or too long is input_invalid" do
      [r] = refusals([profile!("aa", @input_toml)], inputs: %{"mode" => "medium"})
      assert r.code == :input_invalid
      assert r.message =~ ~s<"medium" does not match its pattern '^(fast|slow)$'>

      long = String.duplicate("a", 257)
      [r] = refusals([profile!("aa", @required_toml)], inputs: %{"repo" => long})
      assert r.code == :input_invalid
      assert r.message =~ "at most 256"

      [r] = refusals([profile!("aa", @required_toml)], inputs: %{"repo" => "a\nb"})
      assert r.code == :input_invalid
    end

    test "a value for a name no profile declares is input_unknown" do
      [r] = refusals([profile!("aa", @input_toml)], inputs: %{"mdoe" => "fast"})
      assert r.code == :input_unknown
      assert r.message =~ "the set's inputs are mode"
    end
  end

  describe "custom API connectors in the plan" do
    test "each profile's own, named by its qualified name" do
      a = profile!("aa", custom_toml())

      b = %{
        profile!("bb", String.replace(custom_toml("https://api.other.com"), "API_URL", "B_URL"))
        | qualified: "acme.bb",
          pick: "acme/p/bb@v1"
      }

      plan = merge!([a, b])

      assert [%{name: "aa", provider: "custom_api"}, %{name: "acme.bb", profiles: ["acme.bb"]}] =
               plan.connectors

      text = Plan.format(plan)

      assert text =~
               "custom_api aa  (aa): base URL https://api.example.com, auth header (Bearer), endpoints /v1/*"

      assert text =~ "custom_api acme.bb  (acme/p/bb@v1): base URL https://api.other.com"
    end

    test "an MCP server with auth = \"connector\" is not mcp_needs_login" do
      toml =
        custom_toml() <> ~s([claude.mcp_servers.x]\nurl = "${API_URL}/mcp"\nauth = "connector"\n)

      plan = merge!([profile!("aa", toml)])
      assert Plan.format(plan) =~ "x (http) ${API_URL}/mcp, credential added by the gateway  (aa)"
    end

    test "requires_env still catches an undefined ${KEY}" do
      toml =
        custom_toml() <>
          ~s([claude.mcp_servers.x]\nurl = "${API_URL}/mcp"\nauth = "connector"\nheaders = { X-A = "${NOPE}" }\n)

      [r] = refusals([profile!("aa", toml)])
      assert r.code == :mcp_needs_login
      assert r.message =~ "NOPE"
    end
  end

  describe "check_connectors, custom API" do
    defp custom_plan(toml \\ custom_toml()) do
      p = %{profile!("mcp", toml) | qualified: "acme.mcp", pick: "acme/profiles/mcp@v1"}
      merge!([p])
    end

    defp org(overrides) do
      Map.merge(
        %{
          id: "conn_9",
          provider: "custom_api",
          name: "acme.mcp",
          allow_all: false,
          sprite_labels: ["profile:acme.mcp"],
          name_prefix: nil,
          allowed_endpoints: ["/v1/*"],
          blocked_endpoints: [],
          base_url: "https://api.example.com"
        },
        overrides
      )
    end

    test "matches by provider and name" do
      assert :ok = Merge.check_connectors(custom_plan(), [org(%{})])
    end

    test "another name is connector_missing, naming the command with the pick as written" do
      {:error, [r]} = Merge.check_connectors(custom_plan(), [org(%{name: "mcp"})])
      assert r.code == :connector_missing
      assert r.profiles == ["acme/profiles/mcp@v1"]
      assert r.message =~ "a custom API connector named acme.mcp"

      assert r.message =~
               "base URL https://api.example.com, auth header (Bearer), endpoints /v1/*"

      assert r.message =~ "mix profiles.connect -p acme/profiles/mcp@v1"
      assert r.message =~ "labelled profile:acme.mcp"

      {:error, [r]} = Merge.check_connectors(custom_plan(), [org(%{provider: "github"})])
      assert r.code == :connector_missing
    end

    test "a connector that does not admit the Sprite is connector_not_admitted" do
      {:error, [r]} =
        Merge.check_connectors(custom_plan(), [org(%{sprite_labels: ["profile:other"]})])

      assert r.code == :connector_not_admitted
      assert r.message =~ "mix profiles.connect -p acme/profiles/mcp@v1"

      assert :ok =
               Merge.check_connectors(custom_plan(), [org(%{sprite_labels: [], allow_all: true})])
    end

    test "an endpoint the policy does not cover is connector_endpoints" do
      {:error, [r]} =
        Merge.check_connectors(custom_plan(), [org(%{allowed_endpoints: ["/other"]})])

      assert r.code == :connector_endpoints
      assert r.message =~ "calls /v1/* through the custom API connector acme.mcp"
      assert r.message =~ "allowed: /other; blocked: none"

      {:error, [r]} =
        Merge.check_connectors(custom_plan(), [org(%{blocked_endpoints: ["/V1/admin*"]})])

      assert r.code == :connector_endpoints
    end

    test "a base URL that differs is connector_base_url; a trailing slash does not" do
      {:error, [r]} =
        Merge.check_connectors(custom_plan(), [org(%{base_url: "https://evil.example.com"})])

      assert r.code == :connector_base_url
      assert r.message =~ "points at https://evil.example.com"

      assert :ok =
               Merge.check_connectors(custom_plan(), [
                 org(%{base_url: "https://api.example.com/"})
               ])

      assert :ok = Merge.check_connectors(custom_plan(), [org(%{base_url: nil})])
    end

    test "find_connector picks the named one that admits the Sprite" do
      plan = custom_plan()
      [entry] = plan.connectors
      wanted = org(%{})
      others = [org(%{id: "c1", name: "x"}), org(%{id: "c2", sprite_labels: ["no"]})]
      assert Merge.find_connector(entry, others ++ [wanted], plan.labels, "demo") == wanted
    end
  end

  describe "endpoint_covered?" do
    for {declared, allowed, blocked, want} <- [
          {"/a", ["/a"], [], true},
          {"/a", ["/b"], [], false},
          {"/a/b", ["/a*"], [], true},
          {"/a/b*", ["/a*"], [], true},
          {"/a*", ["/a/b*"], [], false},
          {"/a*", ["/a"], [], false},
          {"/a", ["/a*"], [], true},
          {"/anything/x", [], [], true},
          {"/a/b", [], ["/a/b"], false},
          {"/a/b", [], ["/a*"], false},
          {"/a*", [], ["/a/secret"], false},
          {"/a*", [], ["/a/secret*"], false},
          {"/a/b", [], ["/A/B"], false},
          {"/a/b", ["/a*"], ["/a/c"], true},
          {"/mcp/*", ["/mcp/*"], [], true},
          {"/mcp/*", ["/mcp/"], [], false}
        ] do
      test "#{declared} with allowed #{inspect(allowed)} and blocked #{inspect(blocked)} is #{want}" do
        assert Merge.endpoint_covered?(unquote(declared), unquote(allowed), unquote(blocked)) ==
                 unquote(want)
      end
    end
  end
end

defmodule SpriteProfiles.ProfileTest do
  use ExUnit.Case, async: true

  import SpriteProfiles.ProfileHelpers

  alias SpriteProfiles.Profile

  describe "parse/2" do
    test "reads every field of the format" do
      {:ok, p} =
        parse("full", """
        description = "A paragraph."
        timeout = "15m"
        labels = ["team-a"]

        [env]
        LOG_LEVEL = "info"
        GATEWAY = { from = "connector", provider = "github" }

        [policy]
        rules = [ { include = "defaults" }, { action = "deny", domain = "example.com" } ]

        [[connectors]]
        provider = "github"

        [[services]]
        name = "web"
        cmd = "python3"
        args = ["-m", "http.server", "8080"]
        http_port = 8080
        dir = "~/site"

        [claude.settings.env]
        BASH_DEFAULT_TIMEOUT_MS = "600000"

        [claude.mcp_servers.docs]
        type = "http"
        url = "https://mcp.example.com/mcp"
        auth = "none"
        """)

      assert p.name == "full"
      assert p.timeout == 900
      assert p.labels == ["team-a"]
      assert p.env == %{"LOG_LEVEL" => "info", "GATEWAY" => {:connector, "github"}}
      assert p.policy == [:defaults, {:deny, "example.com"}]
      assert Enum.map(p.connectors, & &1.provider) == ["github"]
      assert [%{name: "web", http_port: 8080, args: ["-m", "http.server", "8080"]}] = p.services
      assert p.claude_settings == %{"env" => %{"BASH_DEFAULT_TIMEOUT_MS" => "600000"}}
      assert [%{name: "docs", type: "http", auth_none: true}] = p.mcp_servers
      assert p.checkpoint
      refute p.privileged
    end

    test "defaults: not privileged, checkpointed, 10 minute timeout, no policy" do
      p = profile!("plain")
      assert {p.privileged, p.checkpoint, p.timeout, p.policy} == {false, true, 600, nil}
    end

    test "a secret in a non-privileged profile is secret_needs_privileged" do
      {:error, errors} = parse("leaky", ~s([env]\nKEY = { secret = "KEY" }))
      assert codes(errors) == [:secret_needs_privileged]
      assert hd(errors).message =~ "profile 'leaky' reads secret \"KEY\" into env KEY"
    end

    test "a secret in a privileged profile is allowed, and the profile is not checkpointed" do
      {:ok, p} = parse("key", ~s(privileged = true\n[env]\nKEY = { secret = "KEY" }))
      assert p.env == %{"KEY" => {:secret, "KEY"}}
      refute p.checkpoint
    end

    test "a privileged profile may not ask to be checkpointed" do
      {:error, errors} = parse("key", "privileged = true\ncheckpoint = true")
      assert codes(errors) == [:privileged_checkpoint]
    end

    test "bad names" do
      for bad <- ["A", "x", "1abc", "has_underscore", String.duplicate("a", 32)] do
        {:error, errors} = Profile.parse(%{"name" => bad, "summary" => "s"}, folder: bad)
        assert :bad_name in codes(errors), "expected #{inspect(bad)} to be refused"
      end
    end

    test "the name must match the folder" do
      {:error, errors} = Profile.parse(%{"name" => "abc", "summary" => "s"}, folder: "abd")
      assert codes(errors) == [:name_mismatch]
    end

    test "unknown fields are refused, at every level" do
      {:error, errors} =
        parse("typo", """
        sumary = "oops"
        [policy]
        rule = []
        [[services]]
        name = "a"
        cmd = "b"
        port = 1
        [claude]
        setting = {}
        """)

      assert codes(errors) == List.duplicate(:unknown_field, 4)
    end

    test "summary is required, one line, at most 80 characters" do
      assert {:error, [%{code: :missing_field}]} = Profile.parse(%{"name" => "ab"}, folder: "ab")

      assert {:error, [%{code: :bad_field}]} =
               parse("ab", ~s(summary = "#{String.duplicate("é", 81)}"))

      assert {:ok, _} = parse("ab", ~s(summary = "#{String.duplicate("é", 80)}"))
      assert {:error, [%{code: :bad_field}]} = parse("ab", ~s(summary = "two\\nlines"))
    end

    test "bad field values" do
      cases = [
        ~s(timeout = "15 minutes"),
        ~s(timeout = "2h"),
        ~s(privileged = "yes"),
        ~s([env]\nlower = "x"),
        ~s([env]\nX = 1),
        ~s([policy]\nrules = [ { action = "maybe", domain = "a.com" } ]),
        ~s([policy]\nrules = [ { action = "allow", domain = "not a domain" } ]),
        ~s([[services]]\nname = "Bad Name"\ncmd = "x"),
        ~s([[services]]\nname = "a"),
        ~s([[services]]\nname = "a"\ncmd = "x"\nhttp_port = 70000),
        ~s([claude.mcp_servers.x]\ntype = "carrier-pigeon"\nurl = "u"),
        ~s([claude.mcp_servers.x]\ntype = "http"),
        ~s([claude.mcp_servers.x]\ntype = "http"\nurl = "u"\nauth = "oauth")
      ]

      for toml <- cases do
        assert {:error, errors} = parse("ab", toml), "expected refusal for #{toml}"

        assert :bad_field in codes(errors),
               "expected bad_field for #{toml}, got #{inspect(codes(errors))}"
      end
    end

    test "env from a connector the profile does not declare" do
      {:error, errors} = parse("ab", ~s([env]\nG = { from = "connector", provider = "github" }))
      assert codes(errors) == [:env_connector_undeclared]
    end

    test "env names the launcher sets are reserved" do
      {:error, errors} = parse("ab", ~s([env]\nPROFILED_SET = "x"))
      assert codes(errors) == [:reserved_env]
    end

    test "profile: labels are reserved" do
      {:error, errors} = parse("ab", ~s(labels = ["profile:github"]))
      assert codes(errors) == [:reserved_label]
    end

    test "one profile may not hold two services of one name, or two http_ports" do
      {:error, errors} =
        parse("ab", """
        [[services]]
        name = "a"
        cmd = "x"
        http_port = 1
        [[services]]
        name = "a"
        cmd = "y"
        http_port = 2
        """)

      assert codes(errors) == [:duplicate_service, :http_port_conflict]
    end

    test "an MCP server's env references count as required env" do
      {:ok, p} =
        parse("ab", """
        [claude.mcp_servers.api]
        type = "http"
        url = "https://api.example.com/mcp"
        headers = { Authorization = "Bearer ${API_TOKEN}" }
        [claude.mcp_servers.local]
        command = "tool"
        args = ["--level", "${LEVEL:-info}"]
        requires_env = ["TOOL_KEY"]
        """)

      [api, local] = p.mcp_servers
      assert api.has_authorization and api.requires_env == ["API_TOKEN"]
      assert local.type == "stdio" and local.requires_env == ["TOOL_KEY"]
      refute Map.has_key?(local.config, "requires_env")
    end
  end

  describe "load/1" do
    @tag :tmp_dir
    test "reads the folder: toml, setup.sh, files/ and claude/skills/", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "demo")
      File.mkdir_p!(Path.join(dir, "files/.config/demo"))
      File.mkdir_p!(Path.join(dir, "claude/skills/howto"))
      File.write!(Path.join(dir, "profile.toml"), ~s(name = "demo"\nsummary = "a demo"\n))
      File.write!(Path.join(dir, "setup.sh"), "#!/bin/sh\n")
      File.write!(Path.join(dir, "files/.config/demo/run.sh"), "#!/bin/sh\n")
      File.chmod!(Path.join(dir, "files/.config/demo/run.sh"), 0o755)
      File.write!(Path.join(dir, "files/.config/demo/conf"), "x\n")
      File.write!(Path.join(dir, "claude/skills/howto/SKILL.md"), "# howto\n")

      {:ok, p} = Profile.load(dir)
      assert p.setup == Path.join(dir, "setup.sh")

      assert [
               %{path: ".config/demo/conf", executable: false},
               %{path: ".config/demo/run.sh", executable: true}
             ] = p.files

      assert [%{name: "howto", files: ["SKILL.md"]}] = p.skills
    end

    @tag :tmp_dir
    test "coded errors for a missing toml, bad TOML, and a skill without SKILL.md", %{
      tmp_dir: tmp
    } do
      assert {:error, [%{code: :missing_profile_toml}]} = Profile.load(Path.join(tmp, "none"))

      bad = Path.join(tmp, "bad")
      File.mkdir_p!(bad)
      File.write!(Path.join(bad, "profile.toml"), "name = ")
      assert {:error, [%{code: :bad_toml}]} = Profile.load(bad)

      skill = Path.join(tmp, "skilly")
      File.mkdir_p!(Path.join(skill, "claude/skills/empty"))
      File.write!(Path.join(skill, "profile.toml"), ~s(name = "skilly"\nsummary = "s"\n))
      assert {:error, [%{code: :bad_skill}]} = Profile.load(skill)
    end

    @tag :tmp_dir
    test "symlinks in files/ are refused", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "linky")
      File.mkdir_p!(Path.join(dir, "files"))
      File.write!(Path.join(dir, "profile.toml"), ~s(name = "linky"\nsummary = "s"\n))
      File.ln_s!("/etc/hosts", Path.join(dir, "files/hosts"))
      assert {:error, [%{code: :bad_file}]} = Profile.load(dir)
    end
  end

  describe "format" do
    test "absent means 1, and 1 is read" do
      assert profile!("aa").format == 1
      assert profile!("aa", "format = 1").format == 1
    end

    test "a newer format is one unsupported_format, before any field check" do
      assert {:error, [e]} = parse("aa", "format = 3\nnew_field = 1\n[inputs]\nx = 1\n")
      assert e.code == :unsupported_format

      assert e.message ==
               "profile 'aa' is format 3; this launcher reads up to format 2, so upgrade sprite-profiles."
    end

    test "a format that is not a whole number is bad_field, with the other errors" do
      assert {:error, errors} = parse("aa", ~s(format = "1"\nbogus = 1))
      assert codes(errors) == [:bad_field, :unknown_field]
      assert {:error, [%{code: :bad_field}]} = parse("aa", "format = 0")
    end
  end

  describe "labels" do
    test "a declared label may be up to 128 characters, the most a Sprite takes" do
      ok = "team:" <> String.duplicate("a", 123)
      assert profile!("aa", "labels = [#{inspect(ok)}]").labels == [ok]
      assert {:error, [%{code: :bad_field}]} = parse("aa", "labels = [#{inspect(ok <> "a")}]")
    end
  end
end

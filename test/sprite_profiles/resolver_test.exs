defmodule SpriteProfiles.ResolverTest do
  # Loading profiles by address, against the Req.Test GitHub stub.
  use ExUnit.Case, async: true

  import SpriteProfiles.GitHubFixtures

  alias SpriteProfiles.{Merge, Plan, Resolver}

  @moduletag :tmp_dir

  setup ctx do
    stub_acme()
    {:ok, opts: [cache_dir: ctx.tmp_dir]}
  end

  defp codes(list), do: Enum.map(list, & &1.code)

  test "an address loads with its qualified name, pick and source", %{opts: opts} do
    assert {:ok, [local, p]} =
             Resolver.find(["preview", "acme/profiles/linear@v2"], ["profiles"], opts)

    assert {local.qualified, local.pick, local.source} == {"preview", "preview", nil}
    assert p.name == "linear"
    assert p.qualified == "acme.linear"
    assert p.pick == "acme/profiles/linear@v2"

    assert p.source == %{
             host: "github.com",
             owner: "acme",
             repo: "profiles",
             path: "linear",
             ref: "v2",
             sha: sha2(),
             kind: :tag,
             version: nil
           }

    assert p.setup =~ Path.join(["github", "acme", "profiles", sha2(), "linear", "setup.sh"])
  end

  test "the last path segment must equal the name", %{opts: opts} do
    assert {:error, [e]} = Resolver.find(["acme/profiles/wrong@v1"], ["profiles"], opts)
    assert e.code == :name_mismatch
    assert e.profile == "acme/profiles/wrong@v1"
    assert e.message =~ "profile 'acme/profiles/wrong@v1'"
  end

  test "at a repository root the repository's name is free", %{opts: opts} do
    assert {:ok, [p]} = Resolver.find(["acme/profiles@v1"], ["profiles"], opts)
    assert p.name == "rooty"
    assert p.qualified == "acme.rooty"
  end

  test "a path the repository lacks is profile_not_found, naming repo and commit",
       %{opts: opts} do
    assert {:error, [r]} = Resolver.find(["acme/profiles/nope@v1"], ["profiles"], opts)
    assert r.code == :profile_not_found
    assert r.message =~ "acme/profiles"
    assert r.message =~ String.slice(sha1(), 0, 8)
  end

  test "a newer format is one refusal, not a flood of unknown fields", %{opts: opts} do
    assert {:error, [e]} = Resolver.find(["acme/profiles/future@v1"], ["profiles"], opts)
    assert e.code == :unsupported_format
    assert e.message =~ "profile 'acme/profiles/future@v1' is format 3"
  end

  test "an addresses-only set does not need the search path to exist", %{opts: opts} do
    assert {:ok, [_]} = Resolver.find(["acme/profiles/linear@v1"], ["/no/such/dir"], opts)
    assert {:error, errs} = Resolver.find(["preview"], ["/no/such/dir"], opts)
    assert :profile_dir_missing in codes(errs)
  end

  test "pins skip resolving: no info/refs request", %{opts: opts} do
    pins = %{"acme/profiles/linear@v1" => %{sha: sha2(), name: "linear"}}
    assert {:ok, [p]} = Resolver.find(["acme/profiles/linear@v1"], [], [pins: pins] ++ opts)
    assert p.source.sha == sha2()
    refute_received {:github, "github.com", _}

    bad = %{"acme/profiles/linear@v1" => %{sha: sha2(), name: "other"}}
    assert {:error, [r]} = Resolver.find(["acme/profiles/linear@v1"], [], [pins: bad] ++ opts)
    assert r.code == :bad_lock
  end

  test "a local profile beside the published one of the same name plans, distinguishably",
       %{opts: opts, tmp_dir: tmp} do
    local = Path.join(tmp, "local")
    File.mkdir_p!(Path.join(local, "linear"))
    File.write!(Path.join([local, "linear", "profile.toml"]), toml("linear"))

    {:ok, profiles} = Resolver.find(["linear", "acme/profiles/linear@v1"], [local], opts)
    assert {:ok, plan} = Merge.merge(profiles)
    assert plan.labels == ["profile:linear", "profile:acme.linear"]

    out = Plan.format(plan)
    assert out =~ "1. linear\n"
    assert out =~ "2. acme/profiles/linear@v1  (setup.sh, up to 10m)"

    assert out =~
             "Sources:\n  acme/profiles/linear@v1  publisher acme, repo acme/profiles, v1 = 1a2b3c4d, setup.sh (up to 10m)"

    assert out =~ "~/.claude/skills/acme.linear--triage/  (acme/profiles/linear@v1)"
    assert out =~ ~s[LINEAR_URL = "https://linear.example"  (acme/profiles/linear@v1)]
  end

  test "two picks with one qualified name are a profile_collision", %{opts: opts} do
    stub(%{
      "acme/a" => %{
        refs: [{"refs/tags/v1", sha1()}],
        archives: %{sha1() => tarball([{"a-x/linear/profile.toml", toml("linear")}])}
      },
      "acme/b" => %{
        refs: [{"refs/tags/v1", sha1()}],
        archives: %{sha1() => tarball([{"b-x/linear/profile.toml", toml("linear")}])}
      }
    })

    {:ok, profiles} = Resolver.find(["acme/a/linear@v1", "acme/b/linear@v1"], [], opts)
    assert {:error, [r]} = Merge.merge(profiles)
    assert r.code == :profile_collision
    assert r.profiles == ["acme/a/linear@v1", "acme/b/linear@v1"]
    assert r.message =~ "profile:acme.linear"
  end
end

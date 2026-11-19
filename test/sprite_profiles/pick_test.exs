defmodule SpriteProfiles.PickTest do
  use ExUnit.Case, async: true

  alias SpriteProfiles.{Merge, Pick}

  test "kind/1: a leading @ is a name, a / or @ an address, anything else local" do
    assert Pick.kind("@acme/linear") == :name
    assert Pick.kind("@acme/linear@1") == :name
    assert Pick.kind("@git.example.com/team/linear") == :name
    assert Pick.kind("acme/profiles/linear@v1") == :address
    assert Pick.kind("acme@v1") == :address
    assert Pick.kind("acme/profiles") == :address
    assert Pick.kind("claude-code") == :local
  end

  test "a name on GitHub, with and without a version" do
    assert {:ok, %Pick{host: "github.com", ns: ["acme"], name: "linear", version: nil}} =
             Pick.parse("@acme/linear")

    assert {:ok, %Pick{version: {:prefix, [1]}}} = Pick.parse("@acme/linear@1")
    assert {:ok, %Pick{version: {:prefix, [1, 2]}}} = Pick.parse("@acme/linear@1.2")
    assert {:ok, %Pick{version: {:prefix, [1, 2, 3]}}} = Pick.parse("@acme/linear@1.2.3")
  end

  test "anything else after @ is a ref" do
    assert {:ok, %Pick{version: {:ref, "main"}}} = Pick.parse("@acme/linear@main")
    assert {:ok, %Pick{version: {:ref, "v1.0.0"}}} = Pick.parse("@acme/linear@v1.0.0")
    assert {:ok, %Pick{version: {:ref, "1.2.3.4"}}} = Pick.parse("@acme/linear@1.2.3.4")

    assert {:ok, %Pick{version: {:ref, "linear/v1.0.0"}}} =
             Pick.parse("@acme/linear@linear/v1.0.0")

    sha = String.duplicate("ab", 20)
    assert {:ok, %Pick{version: {:ref, ^sha}}} = Pick.parse("@acme/linear@" <> sha)
    digits = String.duplicate("54", 20)
    assert {:ok, %Pick{version: {:ref, ^digits}}} = Pick.parse("@acme/linear@" <> digits)
  end

  test "the owner is lowercased, and github.com is the same as no host" do
    assert {:ok, a} = Pick.parse("@Acme/linear@1")
    assert {:ok, b} = Pick.parse("@github.com/acme/linear@2")
    assert {:ok, c} = Pick.parse("@GitHub.com/ACME/linear")
    assert a.ns == ["acme"]
    assert Pick.identity(a) == Pick.identity(b)
    assert Pick.identity(b) == Pick.identity(c)
    assert Pick.base(c) == "@acme/linear"
  end

  test "another host parses, with a port and a namespace of several segments, but is not supported" do
    assert {:ok, p} = Pick.parse("@git.example.com:3000/Team/Sub/linear@1")
    assert p.host == "git.example.com:3000"
    assert p.ns == ["team", "sub"]
    assert p.name == "linear"
    refute Pick.supported?(p)
    assert Pick.base(p) == "@git.example.com:3000/team/sub/linear"
    assert {:ok, %Pick{ns: ["team"]}} = Pick.parse("@localhost:8080/team/linear")
  end

  test "malformed names are bad_name" do
    for bad <- [
          "@acme",
          "@acme/",
          "@/linear",
          "@acme/Linear",
          "@acme/linear@",
          "@acme/linear@/x",
          "@acme/sub/linear",
          "@-acme/linear",
          "@git.example.com/linear",
          "@bad_host.example/team/linear",
          "@git.example.com/te am/linear"
        ] do
      assert Pick.parse(bad) == {:error, :bad_name}, bad
    end
  end

  test "semver and prefix matching ignore pre-releases" do
    assert Pick.semver("1.10.0") == {:ok, [1, 10, 0]}
    assert Pick.semver("1.0.0-rc1") == :error
    {:ok, p} = Pick.parse("@acme/linear@1.2")
    assert Pick.matches?(p, "1.2.9")
    refute Pick.matches?(p, "1.20.0")
    refute Pick.matches?(p, "1.2.0-rc1")
  end

  describe "check_picks with names" do
    defp codes({:error, refusals}), do: Enum.map(refusals, & &1.code)
    defp codes(:ok), do: []

    test "a good name passes, alone or beside a local and an address" do
      assert Merge.check_picks(["claude-code", "@acme/linear@1", "acme/profiles/x@v1"]) == :ok
    end

    test "one name at two versions, or with and without github.com, is duplicate_pick" do
      assert codes(Merge.check_picks(["@acme/linear@1", "@acme/linear@2"])) == [:duplicate_pick]

      assert codes(Merge.check_picks(["@acme/linear", "@github.com/Acme/linear@main"])) ==
               [:duplicate_pick]
    end

    test "a name and an address are not compared before they are fetched" do
      assert Merge.check_picks(["@acme/linear@1", "acme/sprite-profile-linear@v1.0.0"]) == :ok
    end

    test "a malformed name is bad_name, another host is host_not_supported" do
      assert codes(Merge.check_picks(["@acme"])) == [:bad_name]
      assert {:error, [r]} = Merge.check_picks(["@git.example.com/team/linear@1"])
      assert r.code == :host_not_supported
      assert r.message =~ "git.example.com"
      assert r.profiles == ["@git.example.com/team/linear@1"]
    end
  end
end

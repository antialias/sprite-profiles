defmodule SpriteProfiles.AddressTest do
  use ExUnit.Case, async: true

  alias SpriteProfiles.Address

  @sha String.duplicate("ab12", 10)

  test "good addresses parse into owner, repo, path and ref" do
    for {pick, owner, repo, path, ref} <- [
          {"acme/linear@v1", "acme", "linear", "", "v1"},
          {"acme/profiles/linear@v1", "acme", "profiles", "linear", "v1"},
          {"acme/sprites/profiles/linear@#{@sha}", "acme", "sprites", "profiles/linear", @sha},
          {"Acme/Profiles/Linear@main", "Acme", "Profiles", "Linear", "main"},
          {"acme/my.repo_x/a-b@feature/x", "acme", "my.repo_x", "a-b", "feature/x"}
        ] do
      assert {:ok, %Address{owner: ^owner, repo: ^repo, path: ^path, ref: ^ref}} =
               Address.parse(pick),
             pick
    end
  end

  test "bad addresses are refused with a code" do
    for {pick, code} <- [
          {"acme/linear", :address_needs_ref},
          {"acme/profiles/linear", :address_needs_ref},
          {"git.example.com/acme@v1", :bad_address},
          {"git.example.com/repo.git/linear@v1", :bad_address},
          {"git.example.com/a/../b@v1", :bad_address},
          {"git.example.com/a/b c@v1", :bad_address},
          {"git_example.com/a/b@v1", :bad_address},
          {"-git.example.com/a/b@v1", :bad_address},
          {"git.example.com/acme/linear", :address_needs_ref},
          {"acme@v1", :bad_address},
          {"acme/@v1", :bad_address},
          {"acme/profiles//linear@v1", :bad_address},
          {"acme/profiles/../linear@v1", :bad_address},
          {"acme/profiles/./linear@v1", :bad_address},
          {"acme/../x@v1", :bad_address},
          {"-acme/linear@v1", :bad_address},
          {"acme/linear@", :bad_address},
          {"acme/linear@v1..v2/../x", :bad_address},
          {"acme/linear@a b", :bad_address},
          {"acme/li near@v1", :bad_address}
        ] do
      assert Address.parse(pick) == {:error, code}, pick
    end
  end

  test "an address on another host: HOST/OWNER/REPO[/path]@ref, or .git after a namespace" do
    for {pick, host, owner, repo, path} <- [
          {"Git.Example.com/Team/Profiles/linear@v1", "git.example.com", "Team", "Profiles",
           "linear"},
          {"git.example.com/team/profiles.git/linear@v1", "git.example.com", "team", "profiles",
           "linear"},
          {"git.example.com:3000/team/tools@v1", "git.example.com:3000", "team", "tools", ""},
          {"git.example.com/group/sub/tools.git/sprite/linear@v1", "git.example.com", "group/sub",
           "tools", "sprite/linear"},
          {"git.example.com/a/b/c/repo.git@v1", "git.example.com", "a/b/c", "repo", ""},
          {"GitHub.com/acme/profiles/linear@v1", "github.com", "acme", "profiles", "linear"},
          {"acme/profiles.git/linear@v1", "github.com", "acme", "profiles", "linear"}
        ] do
      assert {:ok, %Address{host: ^host, owner: ^owner, repo: ^repo, path: ^path, ref: "v1"}} =
               Address.parse(pick),
             pick
    end
  end

  test "an address without a host, or with github.com, is the same GitHub address" do
    {:ok, a} = Address.parse("acme/profiles/linear@v1")
    {:ok, b} = Address.parse("github.com/acme/profiles/linear@v2")
    assert a.host == "github.com"
    assert Address.identity(a) == Address.identity(b)
    assert Address.to_string(b) == "acme/profiles/linear@v2"
  end

  test "derived forms on another host" do
    {:ok, a} = Address.parse("Git.Example.com:3000/Team/Profiles/linear@v1")
    assert Address.identity(a) == "git.example.com:3000/team/profiles.git/linear"
    assert Address.to_string(a) == "git.example.com:3000/Team/Profiles/linear@v1"
    assert Address.repo_slug(a) == "git.example.com:3000/Team/Profiles"
    assert Address.qualified(a, "linear") == "git.example.com-3000.team.linear"

    {:ok, deep} = Address.parse("git.example.com/group/sub/tools.git/linear@main")
    assert Address.to_string(deep) == "git.example.com/group/sub/tools.git/linear@main"
    assert Address.qualified(deep, "linear") == "git.example.com.group.sub.linear"
    # Read back, it is the same address.
    assert Address.parse(Address.to_string(deep)) == {:ok, deep}

    # The namespace never reads two ways: a/b as owner and repo is not a as owner, b/... .
    {:ok, x} = Address.parse("git.example.com/a/b.git/c@v1")
    {:ok, y} = Address.parse("git.example.com/a/b/c@v1")
    assert Address.identity(x) == Address.identity(y)
    {:ok, z} = Address.parse("git.example.com/a/b/c.git@v1")
    refute Address.identity(y) == Address.identity(z)
  end

  test "a GitHub qualified name has one '.', another host's at least two" do
    {:ok, gh} = Address.parse("acme/profiles/linear@v1")
    {:ok, other} = Address.parse("git.example.com/acme/profiles/linear@v1")
    assert Address.qualified(gh, "linear") == "acme.linear"
    assert Address.qualified(other, "linear") == "git.example.com.acme.linear"
  end

  test "a 40-hex ref is a commit; a short one is a name" do
    assert Address.sha?(@sha)
    refute Address.sha?("ab12ab1")
  end

  test "derived forms" do
    {:ok, a} = Address.parse("Acme/Profiles/linear@v1")
    assert Address.identity(a) == "acme/profiles/linear"
    assert Address.to_string(a) == "Acme/Profiles/linear@v1"
    assert Address.qualified(a, "linear") == "acme.linear"
    assert Address.expected_name(a) == "linear"

    {:ok, root} = Address.parse("acme/linear-profile@v1")
    assert Address.identity(root) == "acme/linear-profile"
    assert Address.expected_name(root) == nil
  end
end

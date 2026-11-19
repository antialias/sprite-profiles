defmodule SpriteProfiles.AddressTest do
  use ExUnit.Case, async: true

  alias SpriteProfiles.Address

  @sha String.duplicate("ab12", 10)

  test "good addresses parse into owner, repo, path and ref" do
    for {pick, owner, repo, path, ref} <- [
          {"acme/linear@v1", "acme", "linear", "", "v1"},
          {"acme/profiles/linear@v1", "acme", "profiles", "linear", "v1"},
          {"acme/sprites/profiles/linear@#{@sha}", "acme", "sprites", "profiles/linear", @sha},
          {"Acme/Profiles/Linear@main", "acme", "profiles", "Linear", "main"},
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
          {"gitlab.example/acme/linear@v1", :bad_address},
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

  test "a 40-hex ref is a commit; a short one is a name" do
    assert Address.sha?(@sha)
    refute Address.sha?("ab12ab1")
  end

  test "derived forms" do
    {:ok, a} = Address.parse("Acme/Profiles/linear@v1")
    assert Address.identity(a) == "acme/profiles/linear"
    assert Address.to_string(a) == "acme/profiles/linear@v1"
    assert Address.qualified(a, "linear") == "acme.linear"
    assert Address.expected_name(a) == "linear"

    {:ok, root} = Address.parse("acme/linear-profile@v1")
    assert Address.identity(root) == "acme/linear-profile"
    assert Address.expected_name(root) == nil
  end
end

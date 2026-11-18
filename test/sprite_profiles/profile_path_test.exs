defmodule SpriteProfiles.ProfilePathTest do
  use ExUnit.Case, async: true

  alias SpriteProfiles.ProfilePath

  @moduletag :tmp_dir

  defp profile!(root, name) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "profile.toml"), ~s(name = "#{name}"\nsummary = "test"\n))
    dir
  end

  describe "dirs/2" do
    test "with nothing given, the repository's profiles folder comes first" do
      assert [first | _] = ProfilePath.dirs([], nil)
      assert first == Path.expand("profiles")
    end

    test "--dir values come before SPRITE_PROFILES_PATH, and replace the default", %{
      tmp_dir: tmp
    } do
      a = Path.join(tmp, "a")
      b = Path.join(tmp, "b")
      c = Path.join(tmp, "c")
      assert ProfilePath.dirs([a, b], "#{c}:#{a}:") == [a, b, c]
      assert ProfilePath.dirs([], c) == [c]
    end
  end

  describe "find/2" do
    test "finds each pick in whichever folder holds it, in pick order", %{tmp_dir: tmp} do
      profile!(Path.join(tmp, "one"), "alpha")
      profile!(Path.join(tmp, "two"), "beta")

      assert {:ok, [b, a]} =
               ProfilePath.find(["beta", "alpha"], [Path.join(tmp, "one"), Path.join(tmp, "two")])

      assert {b.name, a.name} == {"beta", "alpha"}
    end

    test "the same name in two folders is refused, naming both paths", %{tmp_dir: tmp} do
      p1 = profile!(Path.join(tmp, "one"), "alpha")
      p2 = profile!(Path.join(tmp, "two"), "alpha")

      assert {:error, [r]} =
               ProfilePath.find(["alpha"], [Path.join(tmp, "one"), Path.join(tmp, "two")])

      assert r.code == :profile_ambiguous
      assert r.message =~ p1
      assert r.message =~ p2
    end

    test "a pick in no folder is refused, naming the path", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "one")
      File.mkdir_p!(dir)
      assert {:error, [r]} = ProfilePath.find(["alpha"], [dir])
      assert r.code == :profile_not_found
      assert r.message =~ dir
    end

    test "a folder on the path that does not exist is refused", %{tmp_dir: tmp} do
      profile!(Path.join(tmp, "one"), "alpha")
      gone = Path.join(tmp, "gone")
      assert {:error, [r]} = ProfilePath.find(["alpha"], [Path.join(tmp, "one"), gone])
      assert r.code == :profile_dir_missing
      assert r.message =~ gone
    end

    test "the repository's example profiles are found on the default path" do
      assert {:ok, [p]} = ProfilePath.find(["claude-code"], ProfilePath.dirs([], nil))
      assert p.name == "claude-code"
    end
  end
end

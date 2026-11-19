defmodule SpriteProfiles.NamesTest do
  # Name picks (`@owner/name[@V]`) against the Req.Test GitHub stub: where a name is found,
  # which version it resolves to, and that it is the same profile as its address.
  use ExUnit.Case, async: true

  import SpriteProfiles.GitHubFixtures

  alias SpriteProfiles.{Lock, Merge, Names, Pick, Plan, Resolver}

  @moduletag :tmp_dir

  setup ctx do
    stub_names()
    {:ok, opts: [cache_dir: ctx.tmp_dir]}
  end

  defp resolve(pick, opts \\ []) do
    {:ok, p} = Pick.parse(pick)
    Names.resolve(p, pick, opts)
  end

  defp found(pick) do
    {:ok, r} = resolve(pick)
    {r.address.repo, r.address.path, r.address.ref, r.version, r.sha}
  end

  defp requested do
    Stream.repeatedly(fn ->
      receive do
        {:github, host, path} -> {host, path}
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  describe "where a name is found" do
    test "its own repository first, at its root" do
      assert {"sprite-profile-solo", "", "v1.10.0", "1.10.0", sha("53")} == found("@acme/solo")
    end

    test "its own repository wins over the collection, which is never asked" do
      found("@acme/solo")
      paths = Enum.map(requested(), &elem(&1, 1))
      assert paths == ["/acme/sprite-profile-solo.git/info/refs"]
    end

    test "then the collection's folder NAME/, versioned by its own tags" do
      assert {"sprite-profiles", "linear", "linear/v1.1.0", "1.1.0", sha("c3")} ==
               found("@acme/linear")
    end

    test "the folder wins over links.toml, which is not read" do
      found("@acme/linear")
      refute Enum.any?(requested(), fn {_, path} -> path =~ "links.toml" end)
    end

    test "or profiles/NAME/, versioned by the collection's tags when the folder has none" do
      assert {"sprite-profiles", "profiles/plain", "v1.1.0", "1.1.0", sha("c4")} ==
               found("@acme/plain")

      assert {_, _, "v1.0.0", "1.0.0", _} = found("@acme/plain@1.0")
    end

    test "then a pointer in links.toml, versioned by the path's tags only" do
      assert {"platform", "tools/far", "tools/far/v0.1.0", "0.1.0", sha("a2")} ==
               found("@acme/far")

      assert {:error, r} = resolve("@acme/far@9")
      assert r.code == :version_not_found
      assert r.message =~ "acme/platform has 0.1.0"
    end

    test "finding a name reads refs and single files, never an archive" do
      found("@acme/far")
      hosts = requested() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      assert hosts == ["github.com", "raw.githubusercontent.com"]
    end

    test "both folders in the collection is name_ambiguous" do
      assert {:error, r} = resolve("@acme/both")
      assert r.code == :name_ambiguous
      assert r.message =~ "both/ and profiles/both/"
      assert r.profiles == ["@acme/both"]
    end

    test "nothing anywhere is name_not_found, naming the places looked in" do
      assert {:error, r} = resolve("@acme/nothing")
      assert r.code == :name_not_found
      assert r.message =~ "acme/sprite-profile-nothing"
      assert r.message =~ "nothing/ or profiles/nothing/ in acme/sprite-profiles"
      assert r.message =~ "links.toml"

      assert {:error, r} = resolve("@bare-owner/missing")
      assert r.code == :name_not_found
      assert r.message =~ "no collection bare-owner/sprite-profiles"
    end

    test "a link to a missing repository is repo_not_found; a malformed one bad_links" do
      assert {:error, %{code: :repo_not_found}} = resolve("@acme/gone")
      assert {:error, r} = resolve("@acme/crooked")
      assert r.code == :bad_links
      assert r.message =~ "links.toml"
    end

    test "--offline refuses a name it would have to look up" do
      assert {:error, %{code: :not_cached}} = resolve("@acme/solo", offline: true)
      assert requested() == []
    end
  end

  describe "versions" do
    test "no version is the newest, compared as numbers, pre-releases ignored" do
      assert {_, _, "v1.10.0", "1.10.0", _} = found("@acme/solo")
    end

    test "a prefix picks the newest match" do
      assert {_, _, "v1.10.0", "1.10.0", _} = found("@acme/solo@1")
      assert {_, _, "v1.2.0", "1.2.0", _} = found("@acme/solo@1.2")
      assert {_, _, "v1.0.0", "1.0.0", _} = found("@acme/solo@1.0.0")
    end

    test "an annotated tag gives the commit it points at" do
      assert {_, _, "v0.9.0", "0.9.0", sha} = found("@acme/solo@0")
      assert sha == sha("55")
    end

    test "no match is version_not_found, naming what exists; a pre-release never matches" do
      assert {:error, r} = resolve("@acme/solo@2")
      assert r.code == :version_not_found
      assert r.message =~ "asks for version 2"
      assert r.message =~ "1.10.0, 1.2.0, 1.0.0, 0.9.0"
    end

    test "anything else is a ref: a branch, a tag, a commit; no version" do
      assert {:ok, %{kind: :branch, version: nil, sha: s1}} = resolve("@acme/solo@main")
      assert s1 == sha("51")
      assert {:ok, %{kind: :tag, version: nil, sha: s2}} = resolve("@acme/solo@v1.2.0")
      assert s2 == sha("52")

      assert {:ok, %{kind: :commit, version: nil, address: %{ref: ref}}} =
               resolve("@acme/solo@" <> sha("54"))

      assert ref == sha("54")
      assert {:error, %{code: :ref_not_found}} = resolve("@acme/solo@nope")
    end

    test "no version tags and no @V is no_versions, suggesting @main; @main works" do
      assert {:error, r} = resolve("@acme/bare")
      assert r.code == :no_versions
      assert r.message =~ "@acme/bare@main"
      assert {:ok, %{kind: :branch, sha: b1}} = resolve("@acme/bare@main")
      assert b1 == sha("b1")
    end
  end

  describe "through the resolver" do
    test "a name loads with its qualified name, pick and source", %{opts: opts} do
      assert {:ok, [p]} = Resolver.find(["@acme/linear@1.0"], [], opts)
      assert p.name == "linear"
      assert p.qualified == "acme.linear"
      assert p.pick == "@acme/linear@1.0"

      assert p.source == %{
               host: "github.com",
               owner: "acme",
               repo: "sprite-profiles",
               path: "linear",
               ref: "linear/v1.0.0",
               sha: sha("c2"),
               kind: :tag,
               version: "1.0.0"
             }
    end

    test "the profile must declare the name it was picked by", %{opts: opts} do
      assert {:error, [e]} = Resolver.find(["@acme/misnamed"], [], opts)
      assert e.code == :name_mismatch
      assert e.message =~ "@acme/misnamed"
    end

    test "a refusal comes back from find, with the pick", %{opts: opts} do
      assert {:error, [r]} = Resolver.find(["@acme/both"], [], opts)
      assert r.code == :name_ambiguous

      assert {:error, [r]} = Resolver.find(["@git.example.com/team/linear"], [], opts)
      assert r.code == :host_not_supported

      assert {:error, [r]} = Resolver.find(["@git.example.com/group/sub/linear@1"], [], opts)
      assert r.code == :host_not_supported
      assert {:error, %{code: :host_not_supported}} = resolve("@git.example.com/group/sub/linear")
    end

    test "a name and the equivalent address are one profile", %{opts: opts} do
      {:ok, [by_name]} = Resolver.find(["@acme/linear"], [], opts)
      {:ok, [by_addr]} = Resolver.find(["acme/sprite-profiles/linear@linear/v1.1.0"], [], opts)

      assert by_name.qualified == by_addr.qualified
      assert by_name.source.sha == by_addr.source.sha
      assert Merge.skill_folder(by_name, hd(by_name.skills)) == "acme.linear--triage"
      assert Merge.skill_folder(by_addr, hd(by_addr.skills)) == "acme.linear--triage"

      {:ok, plan_name} = Merge.merge([by_name])
      {:ok, plan_addr} = Merge.merge([by_addr])
      assert plan_name.labels == ["profile:acme.linear"]
      assert plan_name.labels == plan_addr.labels

      assert {:error, [r]} = Merge.merge([by_name, by_addr])
      assert r.code == :profile_collision
    end

    test "own repository and its address are one profile too", %{opts: opts} do
      {:ok, [a]} = Resolver.find(["@acme/solo@1.2"], [], opts)
      {:ok, [b]} = Resolver.find(["acme/sprite-profile-solo@v1.2.0"], [], opts)
      assert a.qualified == "acme.solo"
      assert a.qualified == b.qualified
    end

    test "the Sources line shows @owner/name@version = commit", %{opts: opts} do
      {:ok, profiles} = Resolver.find(["@acme/linear@1", "@acme/solo@main"], [], opts)
      {:ok, plan} = Merge.merge(profiles)

      assert Plan.sources(plan) == [
               "@acme/linear@1   publisher acme, repo acme/sprite-profiles, folder linear, @acme/linear@1.1.0 = c3c3c3c3, no setup.sh",
               "@acme/solo@main  publisher acme, repo acme/sprite-profile-solo, @acme/solo@main = 51515151, no setup.sh"
             ]
    end
  end

  describe "the lock" do
    test "format 3 holds a name's version and where it was found, and round-trips",
         %{opts: opts, tmp_dir: tmp} do
      {:ok, profiles} =
        Resolver.find(["claude-code", "@acme/far", "@acme/solo@main"], ["profiles"], opts)

      entries = Lock.entries(profiles)

      assert Enum.at(entries, 1) == %{
               pick: "@acme/far",
               version: "0.1.0",
               host: "github.com",
               owner: "acme",
               repo: "platform",
               path: "tools/far",
               ref: "tools/far/v0.1.0",
               sha: sha("a2"),
               name: "far"
             }

      assert %{version: nil, ref: "main"} = Enum.at(entries, 2)

      text = Lock.encode(entries, ~U[2026-11-19 10:00:00Z])
      assert text =~ "format    = 3\n"
      assert text =~ ~s(version = "0.1.0"\nhost    = "github.com"\n)
      refute text =~ ~s(version = ""\n)

      path = Path.join(tmp, "x.lock")
      File.write!(path, text)
      assert Lock.read(path) == {:ok, entries}
    end

    test "a locked name resolves nothing: no refs, no links.toml", %{opts: opts, tmp_dir: tmp} do
      {:ok, profiles} = Resolver.find(["@acme/far", "@acme/linear@1"], [], opts)
      path = Path.join(tmp, "x.lock")
      Lock.write(path, profiles)
      {:ok, entries} = Lock.read(path)
      requested()

      fresh = Keyword.put(opts, :cache_dir, Path.join(tmp, "fresh"))
      pins = Lock.pins(entries)
      assert {:ok, again} = Resolver.find(Lock.picks(entries), [], [pins: pins] ++ fresh)
      assert Enum.map(again, & &1.qualified) == ["acme.far", "acme.linear"]
      assert Enum.map(again, & &1.source.version) == ["0.1.0", "1.1.0"]
      assert requested() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == ["codeload.github.com"]
    end

    test "a format-2 lock still loads", %{tmp_dir: tmp} do
      path = Path.join(tmp, "old.lock")

      File.write!(path, """
      format    = 2
      locked_at = "2026-11-19T10:00:00Z"

      [inputs]
      readonly = "true"

      [[picks]]
      pick = "claude-code"

      [[picks]]
      pick  = "acme/profiles/linear@v1"
      owner = "acme"
      repo  = "profiles"
      path  = "linear"
      ref   = "v1"
      sha   = "#{sha1()}"
      name  = "linear"
      """)

      assert {:ok, %{picks: [_, %{sha: s}], inputs: %{"readonly" => "true"}}} = Lock.load(path)
      assert s == sha1()
    end

    test "a name in a lock that is wrong is bad_lock", %{opts: opts, tmp_dir: tmp} do
      {:ok, profiles} = Resolver.find(["@acme/solo@1"], [], opts)
      good = Lock.encode(Lock.entries(profiles))

      for {why, text} <- [
            {"format 2 holding a name", String.replace(good, "format    = 3", "format = 2")},
            {"version outside the prefix",
             good
             |> String.replace(~s(version = "1.10.0"), ~s(version = "2.0.0"))
             |> String.replace(~s(ref     = "v1.10.0"), ~s(ref     = "v2.0.0"))},
            {"version not the tag's",
             String.replace(good, ~s(version = "1.10.0"), ~s(version = "1.2.0"))},
            {"no host", String.replace(good, ~s(host    = "github.com"\n), "")},
            {"another host", String.replace(good, ~s("github.com"), ~s("git.example.com"))},
            {"another name", String.replace(good, ~s(name    = "solo"), ~s(name    = "other"))},
            {"another owner", String.replace(good, ~s(owner   = "acme"), ~s(owner   = "other"))}
          ] do
        path = Path.join(tmp, "bad.lock")
        File.write!(path, text)
        assert {:error, [r]} = Lock.read(path), why
        assert r.code == :bad_lock, why
      end
    end

    test "relocking reports a new version" do
      old = [%{pick: "@acme/solo@1", version: "1.2.0", sha: sha("52")}]
      new = [%{pick: "@acme/solo@1", version: "1.10.0", sha: sha("53")}]

      assert Lock.diff(old, new, %{"@acme/solo@1" => :tag}) == [
               "@acme/solo@1: 1.2.0 → 1.10.0 (new version)"
             ]

      moved = [%{pick: "@acme/solo@1", version: "1.2.0", sha: sha("54")}]
      assert [line] = Lock.diff(old, moved, %{"@acme/solo@1" => :tag})
      assert line =~ "(tag moved)"
    end
  end
end

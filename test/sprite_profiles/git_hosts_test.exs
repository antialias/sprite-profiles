defmodule SpriteProfiles.GitHostsTest do
  # Names and addresses on a host other than GitHub, and GitHub's own fallbacks to git, all
  # through file:// bare repositories that the `:git_hosts` option puts behind a host.
  use ExUnit.Case, async: true

  import SpriteProfiles.GitFixtures
  import SpriteProfiles.ProfileHelpers, only: [profile!: 1]

  alias SpriteProfiles.{Address, GitHubFixtures, Lock, Merge, Plan, Resolver}

  doctest SpriteProfiles.Host

  @moduletag :tmp_dir

  @host "git.example.com"

  defp toml(name), do: GitHubFixtures.toml(name)

  # A working repository with `files` committed, then each tag in `tags` on that commit;
  # served bare at `<base>/<path>.git`. Returns the commit.
  defp publish(ctx, path, files, tags) do
    work = init!(Path.join([ctx.tmp_dir, "work", path]))
    sha = commit!(work, files)
    Enum.each(tags, &tag!(work, &1))
    bare = Path.join(ctx.base, path <> ".git")
    File.mkdir_p!(Path.dirname(bare))
    bare!(work, bare)
    sha
  end

  # The example host:
  #   team/sprite-profile-solo   solo at the root; v1.0.0 (s1), v1.1.0 (s2)
  #   team/sprite-profiles       linear/ (linear/v1.0.0), links.toml: far -> platform/tools/far
  #   team/platform              a monorepo: tools/far (tools/far/v0.2.0), its own v9.0.0, and
  #                              a symlink outside tools/far
  #   group/sub/tools            linear/ at main (a namespace of two segments)
  #   group/sub/sprite-profile-deep   deep at the root, v2.0.0
  setup ctx do
    base = Path.join(ctx.tmp_dir, "host")
    ctx = Map.put(ctx, :base, base)

    work = init!(Path.join([ctx.tmp_dir, "work", "solo"]))
    s1 = commit!(work, %{"profile.toml" => toml("solo")})
    tag_annotated!(work, "v1.0.0")
    s2 = commit!(work, %{"profile.toml" => toml("solo") <> "# two\n"})
    tag!(work, "v1.1.0")
    File.mkdir_p!(Path.join(base, "team"))
    bare!(work, Path.join(base, "team/sprite-profile-solo.git"))

    c1 =
      publish(
        ctx,
        "team/sprite-profiles",
        %{
          "linear/profile.toml" => toml("linear"),
          "links.toml" => ~s(far = "platform/tools/far"\n)
        },
        ["linear/v1.0.0"]
      )

    p1 =
      publish(
        ctx,
        "team/platform",
        %{
          "README.md" => "monorepo\n",
          "docs/readme-link" => {:symlink, "../README.md"},
          "tools/far/profile.toml" => toml("far")
        },
        ["v9.0.0", "tools/far/v0.2.0"]
      )

    g1 = publish(ctx, "group/sub/tools", %{"linear/profile.toml" => toml("linear")}, [])

    d1 =
      publish(ctx, "group/sub/sprite-profile-deep", %{"profile.toml" => toml("deep")}, ["v2.0.0"])

    opts = [
      cache_dir: Path.join(ctx.tmp_dir, "cache"),
      git_hosts: %{@host => "file://" <> base}
    ]

    {:ok, base: base, opts: opts, solo_work: work, s1: s1, s2: s2, c1: c1, p1: p1, g1: g1, d1: d1}
  end

  defp find(picks, opts), do: Resolver.find(picks, [], opts)

  describe "names on another host" do
    test "its own repository: the newest version, a host-qualified name, the host in source",
         ctx do
      assert {:ok, [p]} = find(["@git.example.com/team/solo"], ctx.opts)
      assert p.name == "solo"
      assert p.qualified == "git.example.com.team.solo"

      assert p.source == %{
               host: @host,
               owner: "team",
               repo: "sprite-profile-solo",
               path: "",
               ref: "v1.1.0",
               sha: ctx.s2,
               kind: :tag,
               version: "1.1.0"
             }

      # An annotated tag gives its commit.
      assert {:ok, [old]} = find(["@git.example.com/team/solo@1.0"], ctx.opts)
      assert old.source.sha == ctx.s1
    end

    test "the collection's folder, versioned by its tags", ctx do
      assert {:ok, [p]} = find(["@git.example.com/team/linear@1"], ctx.opts)
      assert p.qualified == "git.example.com.team.linear"

      assert {p.source.repo, p.source.path, p.source.ref, p.source.sha} ==
               {"sprite-profiles", "linear", "linear/v1.0.0", ctx.c1}
    end

    test "links.toml, read with git, points into a monorepo whose symlink outside the folder is no fault",
         ctx do
      assert {:ok, [p]} = find(["@git.example.com/team/far"], ctx.opts)

      assert {p.source.repo, p.source.path, p.source.ref, p.source.version, p.source.sha} ==
               {"platform", "tools/far", "tools/far/v0.2.0", "0.2.0", ctx.p1}

      assert p.qualified == "git.example.com.team.far"
    end

    test "a namespace of several segments", ctx do
      assert {:ok, [p]} = find(["@git.example.com/group/sub/deep"], ctx.opts)
      assert p.qualified == "git.example.com.group.sub.deep"

      assert {p.source.owner, p.source.repo, p.source.sha} ==
               {"group/sub", "sprite-profile-deep", ctx.d1}
    end

    test "nothing there is name_not_found, naming the host and the places looked in", ctx do
      assert {:error, [r]} = find(["@git.example.com/team/nope"], ctx.opts)
      assert r.code == :name_not_found

      assert r.message =~
               "git.example.com has no repository git.example.com/team/sprite-profile-nope"

      assert r.message =~ "no nope in its links.toml"
    end

    test "a host with no git is git_missing", ctx do
      assert {:error, [r]} =
               find(["@git.example.com/team/solo"], [git: "no-such-git"] ++ ctx.opts)

      assert r.code == :git_missing
    end

    test "a name and its address are one profile, so a set of both is a profile_collision",
         ctx do
      {:ok, [by_name, by_addr]} =
        find(
          ["@git.example.com/team/linear", "git.example.com/team/sprite-profiles/linear@main"],
          ctx.opts
        )

      assert by_name.qualified == by_addr.qualified
      assert {:error, [r]} = Merge.merge([by_name, by_addr])
      assert r.code == :profile_collision
    end
  end

  describe "addresses on another host" do
    test "HOST/OWNER/REPO/path@ref", ctx do
      assert {:ok, [p]} =
               find(["git.example.com/team/sprite-profiles/linear@linear/v1.0.0"], ctx.opts)

      assert p.qualified == "git.example.com.team.linear"
      assert p.source.host == @host
      assert p.source.kind == :tag
      assert p.source.sha == ctx.c1

      {:ok, plan} = Merge.merge([p])

      assert Plan.sources(plan) == [
               "git.example.com/team/sprite-profiles/linear@linear/v1.0.0  publisher git.example.com/team, repo git.example.com/team/sprite-profiles, linear/v1.0.0 = #{String.slice(ctx.c1, 0, 8)}, no setup.sh"
             ]

      assert plan.labels == ["profile:git.example.com.team.linear"]
    end

    test "a namespace of several segments ends its repository with .git", ctx do
      assert {:ok, [p]} = find(["git.example.com/group/sub/tools.git/linear@main"], ctx.opts)
      assert p.qualified == "git.example.com.group.sub.linear"
      assert {p.source.owner, p.source.repo, p.source.path} == {"group/sub", "tools", "linear"}
      assert p.source.sha == ctx.g1
    end

    test "refusals: no repository, no ref, no folder, a symlink in the folder", ctx do
      assert {:error, [r]} = find(["git.example.com/team/nothing/linear@v1"], ctx.opts)
      assert r.code == :repo_not_found
      assert r.profiles == ["git.example.com/team/nothing/linear@v1"]

      assert {:error, [r]} = find(["git.example.com/team/platform/tools/far@v404"], ctx.opts)
      assert r.code == :ref_not_found

      assert {:error, [r]} = find(["git.example.com/team/platform/tools/gone@v9.0.0"], ctx.opts)
      assert r.code == :profile_not_found

      assert {:error, [r]} = find(["git.example.com/team/platform/docs@v9.0.0"], ctx.opts)
      assert r.code == :bad_archive
      assert r.message =~ "symlink"
    end

    test "--offline needs a lock, then the cache", ctx do
      assert {:error, [r]} =
               find(
                 ["git.example.com/team/platform/tools/far@v9.0.0"],
                 [offline: true] ++ ctx.opts
               )

      assert r.code == :not_cached

      pinned = "git.example.com/team/platform/tools/far@#{ctx.p1}"
      assert {:error, [r]} = find([pinned], [offline: true] ++ ctx.opts)
      assert r.code == :not_cached

      assert {:ok, _} = find([pinned], ctx.opts)
      assert {:ok, [p]} = find([pinned], [offline: true] ++ ctx.opts)
      assert p.source.kind == :commit
    end
  end

  describe "labels" do
    test "label_too_long still guards a host-qualified name" do
      long = String.duplicate("n", 50)
      {:ok, a} = Address.parse("git.example.com/#{long}/#{long}/repo.git/linear@v1")
      q = Address.qualified(a, "linear")
      assert byte_size("profile:" <> q) > Merge.max_label()

      p = %{profile!("linear") | qualified: q, pick: Address.to_string(a)}
      assert {:error, [r]} = Merge.merge([p])
      assert r.code == :label_too_long

      {:ok, short} = Address.parse("git.example.com/team/repo/linear@v1")
      p = %{profile!("linear") | qualified: Address.qualified(short, "linear"), pick: "x/y@v1"}
      assert {:ok, plan} = Merge.merge([p])
      assert plan.labels == ["profile:git.example.com.team.linear"]
      assert Merge.skill_folder(p, %{name: "triage"}) == "git.example.com.team.linear--triage"
    end
  end

  describe "the lock" do
    test "records the host, round-trips, and a locked launch resolves no tag again", ctx do
      picks = [
        "@git.example.com/team/solo@1",
        "git.example.com/group/sub/tools.git/linear@main",
        "@git.example.com/team/far"
      ]

      {:ok, profiles} = find(picks, ctx.opts)
      entries = Lock.entries(profiles)

      assert Enum.at(entries, 0) == %{
               pick: "@git.example.com/team/solo@1",
               version: "1.1.0",
               host: @host,
               owner: "team",
               repo: "sprite-profile-solo",
               path: "",
               ref: "v1.1.0",
               sha: ctx.s2,
               name: "solo"
             }

      assert Enum.at(entries, 1) == %{
               pick: "git.example.com/group/sub/tools.git/linear@main",
               host: @host,
               owner: "group/sub",
               repo: "tools",
               path: "linear",
               ref: "main",
               sha: ctx.g1,
               name: "linear"
             }

      path = Path.join(ctx.tmp_dir, "x.lock")
      Lock.write(path, profiles)
      assert File.read!(path) =~ "format    = 3\n"
      assert {:ok, ^entries} = Lock.read(path)

      # A new version is published; the lock keeps the old one.
      s3 = commit!(ctx.solo_work, %{"profile.toml" => toml("solo") <> "# three\n"})
      tag!(ctx.solo_work, "v1.2.0")

      git!(ctx.solo_work, [
        "push",
        "-q",
        Path.join(ctx.base, "team/sprite-profile-solo.git"),
        "main",
        "v1.2.0"
      ])

      assert {:ok, [now]} = find(["@git.example.com/team/solo@1"], ctx.opts)
      assert now.source.sha == s3

      # From the lock: no ls-remote, no links.toml, no git at all for what is cached.
      locked = [pins: Lock.pins(entries), git: "no-such-git", offline: true] ++ ctx.opts
      assert {:ok, again} = find(Lock.picks(entries), locked)
      assert Enum.map(again, & &1.source.sha) == Enum.map(entries, & &1.sha)
      assert hd(again).source.version == "1.1.0"
      assert Enum.map(again, & &1.qualified) == Enum.map(profiles, & &1.qualified)
    end

    test "an address entry must agree with its host", ctx do
      {:ok, profiles} = find(["git.example.com/team/sprite-profiles/linear@main"], ctx.opts)
      good = Lock.encode(Lock.entries(profiles))
      assert good =~ ~s(host  = "git.example.com"\n)

      for {why, text} <- [
            {"no host", String.replace(good, ~s(host  = "git.example.com"\n), "")},
            {"another host",
             String.replace(good, ~s(host  = "git.example.com"), ~s(host  = "github.com"))}
          ] do
        path = Path.join(ctx.tmp_dir, "bad.lock")
        File.write!(path, text)
        assert {:error, [r]} = Lock.read(path), why
        assert r.code == :bad_lock, why
      end
    end
  end

  describe "GitHub falls back to git" do
    # A private repository: info/refs and codeload know nothing of it, the user's git does.
    setup ctx do
      gh = Path.join(ctx.tmp_dir, "github")
      File.mkdir_p!(Path.join(gh, "hidden"))
      work = init!(Path.join([ctx.tmp_dir, "work", "hidden"]))

      sha =
        commit!(work, %{
          "linear/profile.toml" => toml("linear"),
          "big/profile.toml" => toml("big"),
          "big/files/blob.bin" => String.duplicate("x", 4096),
          "outside" => {:symlink, "linear/profile.toml"}
        })

      tag!(work, "v1.0.0")
      tag!(work, "linear/v1.0.0")
      bare!(work, Path.join(gh, "hidden/sprite-profiles.git"))
      bare!(work, Path.join(gh, "hidden/public.git"))

      GitHubFixtures.stub(%{
        "hidden/plain" => %{
          refs: [{"HEAD", sha}, {"refs/tags/v1.0.0", sha}],
          archives: %{
            sha => GitHubFixtures.tarball([{"plain-#{sha}/linear/profile.toml", toml("linear")}])
          }
        },
        # The same commit, public, served through codeload: an archive with a symlink in it.
        "hidden/public" => %{
          refs: [{"HEAD", sha}, {"refs/heads/main", sha}, {"refs/tags/v1.0.0", sha}],
          archives: %{
            sha =>
              GitHubFixtures.tarball(
                [
                  {"public-#{sha}/linear/profile.toml", toml("linear")},
                  {"public-#{sha}/big/profile.toml", toml("big")},
                  {"public-#{sha}/big/files/blob.bin", String.duplicate("x", 4096)}
                ],
                [{"public-#{sha}/outside", "linear/profile.toml"}]
              )
          }
        }
      })

      opts = Keyword.put(ctx.opts, :git_hosts, %{"github.com" => "file://" <> gh})
      {:ok, gh_opts: opts, hidden: sha}
    end

    test "a private repository's address: refs by ls-remote, codeload's 404, then git", ctx do
      assert {:ok, [p]} = find(["hidden/sprite-profiles/linear@v1.0.0"], ctx.gh_opts)
      assert p.qualified == "hidden.linear"
      assert p.source.host == "github.com"
      assert p.source.sha == ctx.hidden

      assert_received {:github, "github.com", "/hidden/sprite-profiles.git/info/refs"}
      assert_received {:github, "codeload.github.com", _}
    end

    test "a private collection's name: its folder found with git", ctx do
      assert {:ok, [p]} = find(["@hidden/linear"], ctx.gh_opts)
      assert p.qualified == "hidden.linear"

      assert {p.source.repo, p.source.path, p.source.ref} ==
               {"sprite-profiles", "linear", "linear/v1.0.0"}

      refute_received {:github, "raw.githubusercontent.com", _}

      # Locked: no refs, and the cached folder needs no git.
      entries = Lock.entries([p])
      assert [%{host: "github.com"}] = entries
      locked = [pins: Lock.pins(entries), git: "no-such-git", offline: true] ++ ctx.gh_opts
      assert {:ok, [again]} = find(["@hidden/linear"], locked)
      assert again.source.sha == ctx.hidden
    end

    test "no repository anywhere is still repo_not_found", ctx do
      assert {:error, [r]} = find(["hidden/nothing/linear@v1"], ctx.gh_opts)
      assert r.code == :repo_not_found
      assert r.message =~ "credential helper"
    end

    test "an archive over the limit is fetched with git, which checks only the folder", ctx do
      opts = [max_archive: 100] ++ ctx.gh_opts
      assert {:ok, [p]} = find(["hidden/public/big@v1.0.0"], opts)
      assert File.read!(Path.join([p.path, "files", "blob.bin"])) == String.duplicate("x", 4096)
      assert_received {:github, "codeload.github.com", _}

      # The folder itself still has git's limit.
      assert {:error, [r]} =
               find(
                 ["hidden/public/big@v1.0.0"],
                 [max_bytes: 100, cache_dir: Path.join(ctx.tmp_dir, "c2")] ++ opts
               )

      assert r.code == :archive_too_large

      # Without git, the archive's own refusal.
      assert {:error, [r]} =
               find(
                 ["hidden/public/big@v1.0.0"],
                 [git: "no-such-git", cache_dir: Path.join(ctx.tmp_dir, "c3")] ++ opts
               )

      assert r.code == :archive_too_large
      assert r.message =~ "archive"
    end

    test "an archive with a symlink outside the folder is fetched with git", ctx do
      assert {:ok, [p]} = find(["hidden/public/linear@v1.0.0"], ctx.gh_opts)
      assert p.qualified == "hidden.linear"
      # Git's cache entry for the folder, not GitHub's whole repository.
      assert Path.basename(p.path) == "%2Flinear"

      assert {:error, [r]} =
               find(
                 ["hidden/public/linear@v1.0.0"],
                 [git: "no-such-git", cache_dir: Path.join(ctx.tmp_dir, "c4")] ++ ctx.gh_opts
               )

      assert r.code == :bad_archive
    end

    test "a public archive within the limit needs no git", ctx do
      opts = [git: "no-such-git"] ++ ctx.gh_opts
      assert {:ok, [p]} = find(["hidden/plain/linear@v1.0.0"], opts)
      assert p.path =~ Path.join(["github", "hidden", "plain", ctx.hidden, "linear"])
    end
  end
end

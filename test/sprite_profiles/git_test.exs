defmodule SpriteProfiles.GitTest do
  # Not async: one test sets GIT_ASKPASS in the environment to show git never sees it.
  use ExUnit.Case, async: false

  alias SpriteProfiles.{Git, Refusal}
  import SpriteProfiles.GitFixtures

  doctest SpriteProfiles.Git

  @moduletag :tmp_dir

  # The fixture repository:
  #   main (c1): README.md, outside-link -> README.md, profiles/linear/…,
  #              platform/tools/sprite/deep/…, bad/link -> ../README.md; tags v1 (annotated)
  #              and lw1 (lightweight)
  #   c2: profiles/linear changed, reachable only from the annotated tag v2
  #   c3: profiles/linear changed again, reachable only from the lightweight tag lw3
  setup %{tmp_dir: tmp} do
    work = init!(Path.join(tmp, "work"))

    c1 =
      commit!(work, %{
        "README.md" => "# fixture\n",
        "outside-link" => {:symlink, "README.md"},
        "profiles/linear/profile.toml" => "name = \"linear\"\n",
        "profiles/linear/files/notes.txt" => "one\n",
        "platform/tools/sprite/deep/profile.toml" => "name = \"deep\"\n",
        "bad/profile.toml" => "name = \"bad\"\n",
        "bad/link" => {:symlink, "../README.md"}
      })

    tag_annotated!(work, "v1")
    tag!(work, "lw1")

    detach!(work)
    c2 = commit!(work, %{"profiles/linear/files/notes.txt" => "two\n"})
    tag_annotated!(work, "v2")
    c3 = commit!(work, %{"profiles/linear/files/notes.txt" => "three\n"})
    tag!(work, "lw3")
    checkout!(work, "main")

    url = bare!(work, Path.join(tmp, "profiles.git"))
    cache = Path.join(tmp, "cache")

    {:ok, url: url, c1: c1, c2: c2, c3: c3, opts: [cache_dir: cache], tmp: tmp}
  end

  defp dest(ctx, name), do: Path.join([ctx.tmp, "out", name])

  defp notes(dir), do: File.read!(Path.join([dir, "files", "notes.txt"]))

  describe "ls_remote/2" do
    test "lists heads and tags, with annotated tags peeled", ctx do
      assert {:ok, refs} = Git.ls_remote(ctx.url)

      assert refs["HEAD"] == ctx.c1
      assert refs["refs/heads/main"] == ctx.c1
      assert refs["refs/tags/v1^{}"] == ctx.c1
      assert refs["refs/tags/v1"] != ctx.c1
      assert refs["refs/tags/lw1"] == ctx.c1
      refute Map.has_key?(refs, "refs/tags/lw1^{}")
      assert refs["refs/tags/v2^{}"] == ctx.c2
      assert refs["refs/tags/lw3"] == ctx.c3
      assert Enum.all?(Map.values(refs), &(&1 =~ ~r/^[0-9a-f]{40}$/))
    end

    test "a missing repository is repo_not_found", ctx do
      url = "file://" <> Path.join(ctx.tmp, "nope.git")
      assert {:error, %Refusal{code: :repo_not_found, message: msg}} = Git.ls_remote(url)
      assert msg =~ "nope.git"
      assert msg =~ "never asks for them"
    end

    test "no git on PATH is git_missing", ctx do
      assert {:error, %Refusal{code: :git_missing, message: msg}} =
               Git.ls_remote(ctx.url, git: "no-such-git-binary")

      assert msg =~ "git is not on PATH"
    end

    test "a URL git should not be handed is bad_address" do
      for url <- ["ext::sh -c touch% /tmp/x", "-uhelp", "ftp://git.example.com/a/b", "nothing"] do
        assert {:error, %Refusal{code: :bad_address}} = Git.ls_remote(url), url
      end
    end
  end

  describe "fetch/5" do
    test "puts only the folder into dest; a symlink elsewhere in the repo is fine", ctx do
      dest = dest(ctx, "linear")

      assert {:ok, ^dest} = Git.fetch(ctx.url, ctx.c1, "profiles/linear", dest, ctx.opts)
      assert notes(dest) == "one\n"
      assert File.ls!(dest) |> Enum.sort() == ["files", "profile.toml"]
      refute File.exists?(Path.join(dest, "README.md"))
      # The temporary folder is gone.
      assert File.ls!(Path.dirname(dest)) == ["linear"]
    end

    test "a monorepo's deep folder", ctx do
      dest = dest(ctx, "deep")

      assert {:ok, ^dest} =
               Git.fetch(ctx.url, ctx.c1, "platform/tools/sprite/deep", dest, ctx.opts)

      assert File.read!(Path.join(dest, "profile.toml")) == "name = \"deep\"\n"
    end

    test "a symlink inside the folder is refused, and nothing lands", ctx do
      dest = dest(ctx, "bad")

      assert {:error, %Refusal{code: :bad_archive, message: msg}} =
               Git.fetch(ctx.url, ctx.c1, "bad", dest, ctx.opts)

      assert msg =~ "folder bad holds link, a symlink rather than a file"
      refute File.exists?(dest)
      assert File.ls!(Path.dirname(dest)) == []
    end

    test "the root is refused when the repository holds a symlink anywhere", ctx do
      assert {:error, %Refusal{code: :bad_archive, message: msg}} =
               Git.fetch(ctx.url, ctx.c1, "", dest(ctx, "root"), ctx.opts)

      assert msg =~ "repository root holds"
    end

    test "the root of a repository without symlinks", ctx do
      work = init!(Path.join(ctx.tmp, "single"))
      sha = commit!(work, %{"profile.toml" => "name = \"single\"\n", "files/a.txt" => "a\n"})
      url = bare!(work, Path.join(ctx.tmp, "single.git"))
      dest = dest(ctx, "single")

      assert {:ok, ^dest} = Git.fetch(url, sha, "", dest, ctx.opts)
      assert File.ls!(dest) |> Enum.sort() == ["files", "profile.toml"]
    end

    test "a commit reachable only from an annotated tag", ctx do
      dest = dest(ctx, "v2")
      assert {:ok, ^dest} = Git.fetch(ctx.url, ctx.c2, "profiles/linear", dest, ctx.opts)
      assert notes(dest) == "two\n"
    end

    test "a commit reachable only from a lightweight tag", ctx do
      dest = dest(ctx, "lw3")
      assert {:ok, ^dest} = Git.fetch(ctx.url, ctx.c3, "profiles/linear", dest, ctx.opts)
      assert notes(dest) == "three\n"
    end

    test "a server that refuses a want by sha is asked for the tag instead", ctx do
      # Protocol v0 refuses the peeled commit of an annotated tag by sha.
      opts = [git_config: ["protocol.version=0"]] ++ ctx.opts
      dest = dest(ctx, "v0")

      assert {:ok, ^dest} = Git.fetch(ctx.url, ctx.c2, "profiles/linear", dest, opts)
      assert notes(dest) == "two\n"
    end

    test "a commit the repository lacks is ref_not_found", ctx do
      missing = String.duplicate("ab", 20)

      for opts <- [ctx.opts, [git_config: ["protocol.version=0"]] ++ ctx.opts] do
        assert {:error, %Refusal{code: :ref_not_found, message: msg}} =
                 Git.fetch(ctx.url, missing, "profiles/linear", dest(ctx, "missing"), opts)

        assert msg =~ missing
      end
    end

    test "the sha of an annotated tag names the commit to pin instead", ctx do
      {:ok, refs} = Git.ls_remote(ctx.url)

      assert {:error, %Refusal{code: :ref_not_found, message: msg}} =
               Git.fetch(
                 ctx.url,
                 refs["refs/tags/v1"],
                 "profiles/linear",
                 dest(ctx, "t"),
                 ctx.opts
               )

      assert msg =~ "is a tag rather than a commit; pin the commit it points at, #{ctx.c1}."
    end

    test "a short sha is ref_not_found without running git", ctx do
      assert {:error, %Refusal{code: :ref_not_found}} =
               Git.fetch(ctx.url, "abc123", "profiles/linear", dest(ctx, "x"),
                 git: "no-such-git-binary"
               )
    end

    test "a folder the commit lacks is profile_not_found", ctx do
      for path <- ["profiles/nope", "README.md"] do
        assert {:error, %Refusal{code: :profile_not_found, message: msg}} =
                 Git.fetch(ctx.url, ctx.c1, path, dest(ctx, "nope"), ctx.opts)

        assert msg =~ path
      end
    end

    test "a path that climbs out is refused", ctx do
      assert {:error, %Refusal{code: :bad_address}} =
               Git.fetch(ctx.url, ctx.c1, "profiles/../..", dest(ctx, "x"), ctx.opts)
    end

    test "a missing repository is repo_not_found", ctx do
      url = "file://" <> Path.join(ctx.tmp, "nope.git")

      assert {:error, %Refusal{code: :repo_not_found}} =
               Git.fetch(url, ctx.c1, "profiles/linear", dest(ctx, "x"), ctx.opts)
    end

    test "a folder over the size limit is refused", ctx do
      assert {:error, %Refusal{code: :archive_too_large, message: msg}} =
               Git.fetch(ctx.url, ctx.c1, "profiles/linear", dest(ctx, "big"),
                 max_bytes: 10,
                 cache_dir: ctx.opts[:cache_dir]
               )

      assert msg =~ "over 10 bytes"
      refute File.exists?(dest(ctx, "big"))
    end

    test "git is stopped at the timeout", ctx do
      script = Path.join(ctx.tmp, "slow-git")
      File.write!(script, "#!/bin/sh\nexec sleep 30\n")
      File.chmod!(script, 0o755)

      {time, result} =
        :timer.tc(fn -> Git.ls_remote(ctx.url, git: script, timeout: 200) end)

      assert {:error, %Refusal{code: :fetch_failed, message: msg}} = result
      assert msg =~ "longer than"
      assert time < 5_000_000
    end

    test "the timeout kills the children of git too", ctx do
      script = Path.join(ctx.tmp, "parent-git")
      pidfile = Path.join(ctx.tmp, "child.pid")

      # A stand-in for git that starts a child, as git starts git-remote-https or ssh.
      File.write!(script, "#!/bin/sh\nsleep 30 &\necho $! > #{pidfile}\nwait\n")
      File.chmod!(script, 0o755)

      assert {:error, %Refusal{code: :fetch_failed}} =
               Git.ls_remote(ctx.url, git: script, timeout: 500)

      child = pidfile |> File.read!() |> String.trim()
      assert {_, status} = System.cmd("kill", ["-0", child], stderr_to_stdout: true)
      assert status != 0, "the child #{child} outlived the timeout"
    end

    test "git runs with prompts off and no askpass", ctx do
      script = Path.join(ctx.tmp, "env-git")

      File.write!(script, """
      #!/bin/sh
      echo "fatal: prompt=$GIT_TERMINAL_PROMPT askpass=${GIT_ASKPASS-unset} args=$*"
      exit 2
      """)

      File.chmod!(script, 0o755)
      System.put_env("GIT_ASKPASS", "/bin/false")
      on_exit(fn -> System.delete_env("GIT_ASKPASS") end)

      assert {:error, %Refusal{code: :fetch_failed, message: msg}} =
               Git.ls_remote(ctx.url, git: script)

      assert msg =~ "prompt=0 askpass=unset"
      assert msg =~ "-c core.askPass= "
      assert msg =~ "ls-remote #{ctx.url}"
    end
  end

  describe "the cache" do
    test "a fetched folder is cached and runs no git again", ctx do
      refute Git.cached?(ctx.url, ctx.c1, "profiles/linear", ctx.opts)

      assert {:ok, dir} = Git.fetch_cached(ctx.url, ctx.c1, "profiles/linear", ctx.opts)
      assert notes(dir) == "one\n"
      assert String.starts_with?(dir, Git.cache_path(ctx.url, ctx.c1, ctx.opts))
      assert Git.cached?(ctx.url, ctx.c1, "profiles/linear", ctx.opts)

      assert {:ok, ^dir} =
               Git.fetch_cached(
                 ctx.url,
                 ctx.c1,
                 "profiles/linear",
                 [git: "no-such-git-binary"] ++ ctx.opts
               )

      # Another folder of the same commit is not cached by the first.
      refute Git.cached?(ctx.url, ctx.c1, "platform/tools/sprite/deep", ctx.opts)
      refute Git.cached?(ctx.url, ctx.c1, "profiles", ctx.opts)
      refute Git.cached?(ctx.url, ctx.c2, "profiles/linear", ctx.opts)
    end

    test "a folder below a cached folder is cached", ctx do
      assert {:ok, dir} = Git.fetch_cached(ctx.url, ctx.c1, "profiles", ctx.opts)

      assert {:ok, sub} = Git.cached_dir(ctx.url, ctx.c1, "profiles/linear", ctx.opts)
      assert sub == Path.join(dir, "linear")
      refute Git.cached?(ctx.url, ctx.c1, "profiles/nope", ctx.opts)
    end

    test "offline refuses anything not cached", ctx do
      assert {:error, %Refusal{code: :not_cached, message: msg}} =
               Git.fetch_cached(ctx.url, ctx.c1, "profiles/linear", [offline: true] ++ ctx.opts)

      assert msg =~ "--offline"
    end

    test "a refused folder leaves nothing in the cache", ctx do
      assert {:error, %Refusal{code: :bad_archive}} =
               Git.fetch_cached(ctx.url, ctx.c1, "bad", ctx.opts)

      refute Git.cached?(ctx.url, ctx.c1, "bad", ctx.opts)
      assert File.ls!(Git.cache_path(ctx.url, ctx.c1, ctx.opts)) == []
    end

    test "cache paths follow host and repository path" do
      sha = String.duplicate("ab", 20)
      opts = [cache_dir: "/c"]

      assert Git.cache_path("https://git.example.com/acme/profiles.git", sha, opts) ==
               "/c/git.example.com/acme/profiles/#{sha}"

      assert Git.cache_path("git@git.example.com:acme/profiles.git", sha, opts) ==
               "/c/git.example.com/acme/profiles/#{sha}"

      assert Git.cache_path("ssh://git@Git.Example.com:2222/group/sub/repo", sha, opts) ==
               "/c/git.example.com-2222/group/sub/repo/#{sha}"

      assert Git.cache_path("https://user:secret@git.example.com/acme/p", sha, opts) ==
               "/c/git.example.com/acme/p/#{sha}"
    end

    test "a host that is not a host name is refused, so no path leaves the cache root" do
      sha = String.duplicate("ab", 20)

      for url <- [
            "https://../x/y",
            "https://./x/y",
            "https://-x/y/z",
            "https://a_b/x/y",
            "ssh://../x/y",
            "..:x/y",
            "https://git.example.com/../y"
          ] do
        assert Git.repo_key(url) == :error, url
        assert_raise ArgumentError, fn -> Git.cache_path(url, sha, cache_dir: "/c") end
      end

      assert Git.cached?("https://../x/y", sha, "", cache_dir: "/c") == false

      assert {:error, %Refusal{code: :bad_address}} =
               Git.fetch_cached("https://../x/y", sha, "", cache_dir: "/c")
    end

    test "SPRITE_PROFILES_CACHE sets the root" do
      System.put_env("SPRITE_PROFILES_CACHE", "/elsewhere")
      on_exit(fn -> System.delete_env("SPRITE_PROFILES_CACHE") end)

      assert Git.cache_root() == "/elsewhere"
    end
  end

  test "credentials in a URL never reach a sentence" do
    url = "https://user:secret@git.example.com/acme/profiles.git"
    assert Git.redact(url) == "https://git.example.com/acme/profiles.git"

    assert {:error, %Refusal{message: msg}} = Git.ls_remote(url, git: "no-such-git-binary")
    refute msg =~ "secret"

    # A password holding an '@', and a token in a query string.
    assert Git.redact("fatal: https://user:p@ss@git.example.com/a/b.git?token=t0k#frag failed") ==
             "fatal: https://git.example.com/a/b.git failed"

    assert {:error, %Refusal{message: msg}} =
             Git.ls_remote("https://u:p@ss@git.example.com/a/b.git?private_token=t0k",
               git: "no-such-git-binary"
             )

    refute msg =~ "ss@"
    refute msg =~ "t0k"
  end
end

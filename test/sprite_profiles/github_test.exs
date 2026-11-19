defmodule SpriteProfiles.GitHubTest do
  # GitHub is a Req.Test stub (see test/support/github_fixtures.ex); nothing leaves the machine.
  use ExUnit.Case, async: true

  import SpriteProfiles.GitHubFixtures

  alias SpriteProfiles.{Address, GitHub}

  @moduletag :tmp_dir

  defp addr(pick) do
    {:ok, a} = Address.parse(pick)
    a
  end

  defp gh(ctx, extra \\ []), do: [cache_dir: ctx.tmp_dir] ++ extra

  describe "pkt-lines" do
    test "parse drops the service line, flushes and capabilities" do
      refs = GitHub.parse_refs(advertisement(acme_refs()))

      assert refs["HEAD"] == sha1()
      assert refs["refs/heads/main"] == sha1()
      assert refs["refs/tags/v2"] != sha2()
      assert refs["refs/tags/v2^{}"] == sha2()
      refute Enum.any?(Map.keys(refs), &String.contains?(&1, ["service", "multi_ack"]))
    end

    test "a truncated reply keeps what was whole" do
      body = advertisement(acme_refs())
      refs = GitHub.parse_refs(binary_part(body, 0, byte_size(body) - 20))
      assert refs["refs/heads/main"] == sha1()
    end
  end

  describe "resolve" do
    setup do
      stub_acme()
      :ok
    end

    test "a branch, a lightweight tag, and an annotated tag peeled to its commit", ctx do
      assert GitHub.resolve(addr("acme/profiles/linear@main"), gh(ctx)) ==
               {:ok, sha1(), :branch}

      assert GitHub.resolve(addr("acme/profiles/linear@v1"), gh(ctx)) == {:ok, sha1(), :tag}
      assert GitHub.resolve(addr("acme/profiles/linear@v2"), gh(ctx)) == {:ok, sha2(), :tag}
    end

    test "a name that is both a tag and a branch is refused", ctx do
      assert {:error, r} = GitHub.resolve(addr("acme/profiles/linear@twice"), gh(ctx))
      assert r.code == :ref_ambiguous
      assert r.profiles == ["acme/profiles/linear@twice"]
    end

    test "an unknown ref, and a short SHA, are ref_not_found", ctx do
      for ref <- ["v9", String.slice(sha1(), 0, 7)] do
        assert {:error, r} = GitHub.resolve(addr("acme/profiles/linear@#{ref}"), gh(ctx))
        assert r.code == :ref_not_found
      end
    end

    test "a missing (or private) repository is repo_not_found", ctx do
      assert {:error, r} = GitHub.resolve(addr("acme/nope/linear@v1"), gh(ctx))
      assert r.code == :repo_not_found
      assert r.message =~ "acme/nope"
      assert r.message =~ "private"
    end

    test "a 40-hex ref, or --offline, makes no request", ctx do
      assert GitHub.resolve(addr("acme/profiles/linear@#{sha1()}"), gh(ctx)) ==
               {:ok, sha1(), :commit}

      assert {:error, r} = GitHub.resolve(addr("acme/profiles/linear@v1"), gh(ctx, offline: true))
      assert r.code == :not_cached
      refute_received {:github, _, _}
    end

    test "any other status is fetch_failed, naming the URL", ctx do
      Req.Test.stub(GitHub, &Plug.Conn.send_resp(&1, 500, "oops"))
      assert {:error, r} = GitHub.resolve(addr("acme/profiles/linear@v1"), gh(ctx))
      assert r.code == :fetch_failed
      assert r.message =~ "info/refs"
      assert r.message =~ "500"
    end
  end

  describe "fetch" do
    setup do
      stub_acme()
      :ok
    end

    test "lands the repository in the cache under its commit, once", ctx do
      a = addr("acme/profiles/linear@v1")
      refute GitHub.cached?(a, sha1(), gh(ctx))

      assert {:ok, dir} = GitHub.fetch(a, sha1(), gh(ctx))
      assert dir == Path.join([ctx.tmp_dir, "github", "acme", "profiles", sha1()])
      assert File.regular?(Path.join(dir, "linear/profile.toml"))
      assert GitHub.cached?(a, sha1(), gh(ctx))
      assert_received {:github, "codeload.github.com", _}

      assert {:ok, ^dir} = GitHub.fetch(a, sha1(), gh(ctx))
      refute_received {:github, _, _}
      assert File.ls!(Path.dirname(dir)) == [sha1()]
    end

    test "--offline uses the cache and refuses what it lacks", ctx do
      a = addr("acme/profiles/linear@v1")
      assert {:error, r} = GitHub.fetch(a, sha1(), gh(ctx, offline: true))
      assert r.code == :not_cached
      assert r.message =~ GitHub.cache_path(a, sha1(), gh(ctx))

      {:ok, _} = GitHub.fetch(a, sha1(), gh(ctx))
      assert {:ok, _} = GitHub.fetch(a, sha1(), gh(ctx, offline: true))
    end

    test "a commit the repository lacks is ref_not_found", ctx do
      assert {:error, r} =
               GitHub.fetch(
                 addr("acme/profiles/linear@v1"),
                 sha2() |> String.replace("4", "0"),
                 gh(ctx)
               )

      assert r.code == :ref_not_found
    end

    test "an archive over the limit is refused", ctx do
      big = :binary.copy("x", GitHub.max_archive() + 1)
      stub(%{"acme/big" => %{refs: [], archives: %{sha1() => big}}})
      assert {:error, r} = GitHub.fetch(addr("acme/big@#{sha1()}"), sha1(), gh(ctx))
      assert r.code == :archive_too_large
    end

    test "bad archives are refused and nothing lands", ctx do
      top = "x-#{sha1()}"

      for {why, body} <- [
            {"climbs out", tarball([{"#{top}/profile.toml", "x"}, {"#{top}/../evil", "x"}])},
            {"a symlink",
             tarball([{"#{top}/profile.toml", "x"}], [{"#{top}/link", "/etc/passwd"}])},
            {"2 top-level entries", tarball([{"a/profile.toml", "x"}, {"b/profile.toml", "x"}])},
            {"could not be read", "not gzip at all"}
          ] do
        stub(%{"acme/bad" => %{refs: [], archives: %{sha1() => body}}})
        a = addr("acme/bad@#{sha1()}")
        assert {:error, r} = GitHub.fetch(a, sha1(), gh(ctx)), why
        assert r.code == :bad_archive, why
        assert r.message =~ why
        refute GitHub.cached?(a, sha1(), gh(ctx)), why
      end
    end
  end

  test "the cache_dir option sets the cache root" do
    assert GitHub.cache_root(cache_dir: "/x/y") == "/x/y"

    assert GitHub.cache_path(addr("acme/p/l@v1"), sha1(), cache_dir: "/x/y") ==
             "/x/y/github/acme/p/#{sha1()}"
  end
end

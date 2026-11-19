defmodule SpriteProfiles.GitHubFixtures do
  @moduledoc """
  A fake GitHub for tests, served through `Req.Test`: ref advertisements in pkt-lines,
  `.tar.gz` archives built in the test, and single files as `raw.githubusercontent.com`
  serves them. Every request is sent to the test process as `{:github, host, path}`, so a
  test can assert what was (or was not) called.

  `names_repos/0` is a small world of published names (owner `acme`) for name resolution.
  """

  @sha1 String.duplicate("1a2b3c4d", 5)
  @sha2 String.duplicate("4d5e6f7a", 5)
  @tag_obj String.duplicate("9f9f9f9f", 5)

  def sha1, do: @sha1
  def sha2, do: @sha2

  @doc "A made-up 40-hex commit, `n` repeated (`sha(\"c1\")`)."
  def sha(n), do: n |> String.duplicate(40) |> binary_part(0, 40)

  @doc "One pkt-line: four hex digits of length, then the payload."
  def pkt(payload),
    do:
      (byte_size(payload) + 4)
      |> Integer.to_string(16)
      |> String.pad_leading(4, "0")
      |> String.downcase()
      |> Kernel.<>(payload)

  @doc """
  A ref advertisement as github.com serves it: the service line, a flush, HEAD with
  capabilities after a NUL, then each ref, then a flush.
  """
  def advertisement(refs) do
    [{_, head_sha} | _] = refs

    pkt("# service=git-upload-pack\n") <>
      "0000" <>
      pkt("#{head_sha} HEAD\0multi_ack thin-pack side-band symref=HEAD:refs/heads/main\n") <>
      Enum.map_join(refs, "", fn {name, sha} -> pkt("#{sha} #{name}\n") end) <>
      "0000"
  end

  @doc "The refs of the fixture repository acme/profiles."
  def acme_refs do
    [
      {"refs/heads/main", @sha1},
      {"refs/heads/twice", @sha1},
      {"refs/tags/v1", @sha1},
      {"refs/tags/v2", @tag_obj},
      {"refs/tags/v2^{}", @sha2},
      {"refs/tags/twice", @sha2}
    ]
  end

  @doc "A profile.toml for `name`, with extra TOML appended."
  def toml(name, extra \\ ""),
    do: ~s(name = "#{name}"\nsummary = "test profile #{name}"\n) <> extra

  @doc """
  The fixture repository at one commit: `linear/` (env, setup.sh, a skill), `wrong/`
  (declares another name) and a root `profile.toml` named `rooty`.
  """
  def acme_files(top \\ "profiles-#{@sha1}") do
    [
      {"#{top}/profile.toml", toml("rooty")},
      {"#{top}/linear/profile.toml",
       toml("linear", ~s([env]\nLINEAR_URL = "https://linear.example"\n))},
      {"#{top}/linear/setup.sh", "#!/usr/bin/env bash\necho linear\n"},
      {"#{top}/linear/claude/skills/triage/SKILL.md", "---\nname: triage\n---\nTriage.\n"},
      {"#{top}/wrong/profile.toml", toml("not-wrong")},
      {"#{top}/future/profile.toml",
       "format = 3\nname = \"future\"\nsummary = \"x\"\nnew_thing = 1\n"}
    ]
  end

  @doc """
  A `.tar.gz` holding `files` (`{name, content}`), plus `symlinks` (`{name, target}`).
  """
  def tarball(files, symlinks \\ []) do
    dir = Path.join(System.tmp_dir!(), "gh-fixture-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "a.tar.gz")

    try do
      {:ok, fd} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])

      for {name, content} <- files,
          do: :ok = :erl_tar.add(fd, content, String.to_charlist(name), [])

      for {name, target} <- symlinks do
        link = Path.join(dir, "link-#{System.unique_integer([:positive])}")
        File.ln_s!(target, link)
        :ok = :erl_tar.add(fd, String.to_charlist(link), String.to_charlist(name), [])
      end

      :ok = :erl_tar.close(fd)
      File.read!(path)
    after
      File.rm_rf!(dir)
    end
  end

  @doc """
  A fixture repository `owner/repo` from its refs and, per commit, its files
  (`{path, content}` relative to the repository root): archives for codeload and the same
  files for raw.
  """
  def repo(slug, refs, commits) do
    name = slug |> String.split("/") |> List.last()

    %{
      refs: refs,
      archives:
        Map.new(commits, fn {sha, files} ->
          {sha, tarball(Enum.map(files, fn {path, c} -> {"#{name}-#{sha}/#{path}", c} end))}
        end),
      raw: Map.new(commits, fn {sha, files} -> {sha, Map.new(files)} end)
    }
  end

  @doc """
  Stubs GitHub for the calling test. `repos` maps `"owner/repo"` to
  `%{refs: [...], archives: %{sha => tarball}, raw: %{sha => %{path => text}}}` (`raw`
  optional); anything else is a 404 (401 for `info/refs`, as github.com answers).
  """
  def stub(repos) do
    test = self()

    Req.Test.stub(SpriteProfiles.GitHub, fn conn ->
      send(test, {:github, conn.host, conn.request_path})

      case {conn.host, String.split(conn.request_path, "/", trim: true)} do
        {"github.com", [owner, repo_git, "info", "refs"]} ->
          case repos["#{owner}/#{String.trim_trailing(repo_git, ".git")}"] do
            %{refs: refs} -> Plug.Conn.send_resp(conn, 200, advertisement(refs))
            _ -> Plug.Conn.send_resp(conn, 401, "")
          end

        {"raw.githubusercontent.com", [owner, repo, sha | path]} ->
          case get_in(repos, ["#{owner}/#{repo}", :raw, sha, Enum.join(path, "/")]) do
            nil -> Plug.Conn.send_resp(conn, 404, "404: Not Found")
            text -> Plug.Conn.send_resp(conn, 200, text)
          end

        {"codeload.github.com", [owner, repo, "tar.gz", sha]} ->
          case get_in(repos, ["#{owner}/#{repo}", :archives, sha]) do
            nil -> Plug.Conn.send_resp(conn, 404, "")
            body -> Plug.Conn.send_resp(conn, 200, body)
          end

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  @doc "Stubs the fixture repository acme/profiles at both its commits."
  def stub_acme do
    stub(%{
      "acme/profiles" => %{
        refs: acme_refs(),
        archives: %{
          @sha1 => tarball(acme_files("profiles-#{@sha1}")),
          @sha2 => tarball(acme_files("profiles-#{@sha2}"))
        }
      }
    })
  end

  ## names

  @doc """
  Published names of owner `acme` (and `bare-owner`, who has no collection):

    * `acme/sprite-profile-solo`, its own repository: `v1.0.0` (`s1`), `v1.2.0` (`s2`),
      `v1.10.0` (`s3`), the pre-release `v2.0.0-rc1` (`s4`), and `v0.9.0`, an annotated
      tag of `s5`. HEAD and `main` are `s1`.
    * `acme/sprite-profile-bare`: no tags; `main` is `b1`.
    * `acme/sprite-profile-misnamed`: `v1.0.0` declares the name `other`.
    * `acme/sprite-profiles`, the collection, HEAD `c1`: `linear/` (tags `linear/v1.0.0`
      `c2` and `linear/v1.1.0` `c3`), `profiles/plain/` (versioned by the collection's own
      `v1.0.0` `c1` and `v1.1.0` `c4`), `both/` and `profiles/both/` (ambiguous), `solo/`
      (shadowed by the repository of its own), and `links.toml` pointing `far` at
      `platform/tools/far`, `linear` at `platform/tools/linear` (shadowed by the folder),
      `gone` at a missing repository and `crooked` at a bare repository name.
    * `acme/platform`, a monorepo: its own `v9.0.0` (`p1`) and `tools/far/v0.1.0` (`p2`).
  """
  def names_repos do
    s = &sha/1
    root = fn name -> [{"profile.toml", toml(name)}] end

    collection_files = [
      {"linear/profile.toml", toml("linear")},
      {"linear/claude/skills/triage/SKILL.md", "---\nname: triage\n---\nTriage.\n"},
      {"profiles/plain/profile.toml", toml("plain")},
      {"both/profile.toml", toml("both")},
      {"profiles/both/profile.toml", toml("both")},
      {"solo/profile.toml", toml("solo")},
      {"links.toml",
       ~s(far = "platform/tools/far"\nlinear = "platform/tools/linear"\ngone = "no-such-repo/x/gone"\ncrooked = "platform"\n)}
    ]

    %{
      "acme/sprite-profile-solo" =>
        repo(
          "acme/sprite-profile-solo",
          [
            {"HEAD", s.("51")},
            {"refs/heads/main", s.("51")},
            {"refs/tags/v1.0.0", s.("51")},
            {"refs/tags/v1.2.0", s.("52")},
            {"refs/tags/v1.10.0", s.("53")},
            {"refs/tags/v2.0.0-rc1", s.("54")},
            {"refs/tags/v0.9.0", s.("5f")},
            {"refs/tags/v0.9.0^{}", s.("55")}
          ],
          Map.new(~w(51 52 53 54 55), &{s.(&1), root.("solo")})
        ),
      "acme/sprite-profile-bare" =>
        repo(
          "acme/sprite-profile-bare",
          [{"HEAD", s.("b1")}, {"refs/heads/main", s.("b1")}],
          %{s.("b1") => root.("bare")}
        ),
      "acme/sprite-profile-misnamed" =>
        repo(
          "acme/sprite-profile-misnamed",
          [{"HEAD", s.("e1")}, {"refs/tags/v1.0.0", s.("e1")}],
          %{s.("e1") => root.("other")}
        ),
      "acme/sprite-profiles" =>
        repo(
          "acme/sprite-profiles",
          [
            {"HEAD", s.("c1")},
            {"refs/heads/main", s.("c1")},
            {"refs/tags/v1.0.0", s.("c1")},
            {"refs/tags/v1.1.0", s.("c4")},
            {"refs/tags/linear/v1.0.0", s.("c2")},
            {"refs/tags/linear/v1.1.0", s.("c3")}
          ],
          Map.new(~w(c1 c2 c3 c4), &{s.(&1), collection_files})
        ),
      "acme/platform" =>
        repo(
          "acme/platform",
          [
            {"HEAD", s.("a1")},
            {"refs/heads/main", s.("a1")},
            {"refs/tags/v9.0.0", s.("a1")},
            {"refs/tags/tools/far/v0.1.0", s.("a2")}
          ],
          Map.new(~w(a1 a2), &{s.(&1), [{"tools/far/profile.toml", toml("far")}]})
        ),
      "bare-owner/sprite-profile-only" =>
        repo(
          "bare-owner/sprite-profile-only",
          [{"HEAD", s.("d1")}, {"refs/tags/v1.0.0", s.("d1")}],
          %{s.("d1") => root.("only")}
        )
    }
  end

  @doc "Stubs the names world, plus acme/profiles of `stub_acme/0`."
  def stub_names do
    stub(
      Map.merge(names_repos(), %{
        "acme/profiles" => %{
          refs: acme_refs(),
          archives: %{@sha1 => tarball(acme_files("profiles-#{@sha1}"))}
        }
      })
    )
  end
end

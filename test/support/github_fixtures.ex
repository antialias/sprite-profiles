defmodule SpriteProfiles.GitHubFixtures do
  @moduledoc """
  A fake GitHub for tests, served through `Req.Test`: ref advertisements in pkt-lines and
  `.tar.gz` archives built in the test. Every request is sent to the test process as
  `{:github, host, path}`, so a test can assert what was (or was not) called.
  """

  @sha1 String.duplicate("1a2b3c4d", 5)
  @sha2 String.duplicate("4d5e6f7a", 5)
  @tag_obj String.duplicate("9f9f9f9f", 5)

  def sha1, do: @sha1
  def sha2, do: @sha2

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
       "format = 2\nname = \"future\"\nsummary = \"x\"\nnew_thing = 1\n"}
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
  Stubs GitHub for the calling test. `repos` maps `"owner/repo"` to
  `%{refs: [...], archives: %{sha => tarball}}`; anything else is a 404.
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
end

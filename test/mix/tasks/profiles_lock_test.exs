defmodule Mix.Tasks.Profiles.LockTest do
  # mix profiles.lock, and --lock / --offline on plan and launch, against the Req.Test
  # GitHub stub. The cache is a temporary folder (SPRITE_PROFILES_CACHE).
  use ExUnit.Case

  import ExUnit.CaptureIO
  import SpriteProfiles.GitHubFixtures

  alias Mix.Tasks.Profiles.{Launch, Lock, Plan}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Mix.shell(Mix.Shell.Process)
    saved = System.get_env("SPRITE_PROFILES_CACHE")
    System.put_env("SPRITE_PROFILES_CACHE", Path.join(tmp, "cache"))

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)

      if saved,
        do: System.put_env("SPRITE_PROFILES_CACHE", saved),
        else: System.delete_env("SPRITE_PROFILES_CACHE")
    end)

    stub_acme()
    {:ok, lock: Path.join(tmp, "set.lock")}
  end

  defp output do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, _kind, [line]} -> line
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
    |> Enum.join("\n")
  end

  defp flush_github do
    receive do
      {:github, _, _} -> flush_github()
    after
      0 -> :ok
    end
  end

  test "lock, then plan from the lock offline: no request at all", %{lock: lock} do
    Lock.run(["-p", "claude-code", "-p", "acme/profiles/linear@v1", "-o", lock])
    out = output()
    assert out =~ "acme/profiles/linear@v1  tag v1 = 1a2b3c4d"
    assert out =~ "Locked 2 picks in #{lock}"
    assert File.read!(lock) =~ ~s(sha   = "#{sha1()}")
    flush_github()

    Plan.run(["--lock", lock, "--offline"])
    out = output()
    assert out =~ "Plan for claude-code+acme/profiles/linear@v1"
    assert out =~ "Sources:\n  acme/profiles/linear@v1  publisher acme"
    assert out =~ "profile:acme.linear"
    refute_received {:github, _, _}
  end

  test "a locked launch resolves nothing", %{lock: lock} do
    Lock.run(["-p", "acme/profiles/linear@v1", "-o", lock])
    output()
    flush_github()

    Launch.run(["--lock", lock, "--dry-run"])
    assert output() =~ "Dry run: nothing was created."
    refute_received {:github, "github.com", _}
  end

  test "--offline without a lock, or with an uncached commit, is not_cached", %{lock: lock} do
    assert catch_exit(Plan.run(["-p", "acme/profiles/linear@v1", "--offline"])) ==
             {:shutdown, 1}

    assert output() =~ "[not_cached]"

    File.write!(
      lock,
      SpriteProfiles.Lock.encode([
        %{
          pick: "acme/profiles/linear@v1",
          owner: "acme",
          repo: "profiles",
          path: "linear",
          ref: "v1",
          sha: sha2(),
          name: "linear"
        }
      ])
    )

    assert catch_exit(Plan.run(["--lock", lock, "--offline"])) == {:shutdown, 1}
    assert output() =~ "[not_cached] profile 'acme/profiles/linear@v1' is pinned to 4d5e6f7a"
  end

  test "locking again reports a moved tag", %{lock: lock} do
    Lock.run(["-p", "acme/profiles/linear@v1", "-o", lock])
    output()

    moved =
      Enum.map(acme_refs(), fn
        {"refs/tags/v1", _} -> {"refs/tags/v1", sha2()}
        other -> other
      end)

    stub(%{
      "acme/profiles" => %{
        refs: moved,
        archives: %{sha2() => tarball(acme_files("profiles-#{sha2()}"))}
      }
    })

    Lock.run(["-p", "acme/profiles/linear@v1", "-o", lock])
    assert output() =~ "Moved: acme/profiles/linear@v1: 1a2b3c4d → 4d5e6f7a (tag moved)"
    assert File.read!(lock) =~ sha2()
  end

  test "a set that does not plan is not locked", %{lock: lock} do
    assert catch_exit(Lock.run(["-p", "preview", "-p", "preview", "-o", lock])) ==
             {:shutdown, 1}

    assert output() =~ "[duplicate_pick]"
    refute File.exists?(lock)
  end

  test "a plan of local profiles has no Sources section" do
    Plan.run(["-p", "preview"])
    refute output() =~ "Sources"
  end

  test "--lock with --profile is bad usage, exit 2", %{lock: lock} do
    capture_io(:stderr, fn ->
      assert catch_exit(Plan.run(["--lock", lock, "-p", "preview"])) == {:shutdown, 2}
      assert catch_exit(Launch.run(["--lock", lock, "-p", "preview"])) == {:shutdown, 2}
    end)

    assert output() =~ "--lock and --profile name the set twice"
  end

  test "an unreadable lock is bad_lock, exit 1", %{lock: lock} do
    assert catch_exit(Plan.run(["--lock", lock])) == {:shutdown, 1}
    assert output() =~ "[bad_lock]"
  end
end

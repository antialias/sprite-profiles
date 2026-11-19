defmodule SpriteProfiles.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SpriteProfiles.{CLI, Plan, Planner, ProfilePath}

  @profiles Path.expand("../../profiles", __DIR__)

  defp run(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:status, CLI.main(argv)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  defp expected(picks, opts \\ []) do
    {:ok, plan} =
      Planner.plan(picks, [dirs: [@profiles], caller: :person, inputs: %{}] ++ opts)

    Plan.format(plan) <> "\n"
  end

  test "--version prints the version" do
    assert {0, "sprite-profiles " <> version, ""} = run(["--version"])
    assert String.trim(version) == CLI.version()
  end

  test "help prints usage on stdout" do
    assert {0, "sprite-profiles: " <> _, ""} = run(["help"])
  end

  test "an unknown command prints help on stderr and exits 2" do
    assert {2, "", "sprite-profiles: " <> _} = run(["frobnicate"])
    assert {2, "", _} = run([])
  end

  test "plan takes positional picks and -p alike, in the order given" do
    want = expected(["claude-code", "github"])

    assert {0, ^want, ""} = run(["plan", "claude-code", "github", "--dir", @profiles])
    assert {0, ^want, ""} = run(["plan", "-p", "claude-code", "github", "--dir", @profiles])
    assert {0, ^want, ""} = run(["plan", "--dir", @profiles, "claude-code", "-p", "github"])
  end

  test "plan refuses an unknown profile with exit 1" do
    assert {1, "", "Refused:\n  [profile_not_found]" <> _} =
             run(["plan", "no-such-profile", "--dir", @profiles])
  end

  test "plan with no picks, or an unknown option, is bad usage" do
    assert {2, "", err} = run(["plan"])
    assert err =~ "name at least one profile"
    assert {2, "", err} = run(["plan", "claude-code", "--frob"])
    assert err =~ "not understood: --frob"
  end

  test "the search path is ProfilePath's when nothing is bundled or a folder is given" do
    assert CLI.bundled_profiles() == nil
    assert CLI.search_path([], nil) == ProfilePath.dirs([], nil)
    assert CLI.search_path(["x"], nil) == [Path.expand("x")]
  end
end
